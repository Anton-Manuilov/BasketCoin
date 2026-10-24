// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BasketToken} from "./BasketToken.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {DateLib} from "./libraries/DateLib.sol";

/// @title BasketVault
/// @author BasketCoin
/// @notice Хранилище залога и минтер для токенов-корзин BasketCoin.
///
/// Единицы:
///  - индекс / рабочая цена корзины (P) — цена 1 токена корзины в USD, 18 знаков (1e18 = $1);
///  - цена стейбла (p) — USD за 1 целую единицу стейбла, 18 знаков;
///  - minMintUsd — USD, 18 знаков.
///
/// Формулы (BUFFER_BPS = 2000 = 20%; FEE_BPS = 30 = 0,3%). Все округления — в пользу протокола:
///  МИНТ:   fee      = ceil(received * 0,3%)                 (в стейбле, уходит в казну)
///          net      = received - fee                        (остаётся в резерве)
///          tokens   = floor(net * min(p, $1) / (P * 1,2))   (одно округление)
///          => каждый выпущенный токен обеспечен не менее чем 120% его стоимости по P.
///          Минимальный минт проверяется по floor(received * min(p, $1)) — до комиссии протокола,
///          после комиссии самого токена за перевод (если она есть).
///  ПОКРЫТИЕ корзины (coverage, bps, floor):
///          coverage = Σ_стейблы reserve_i * min(p_i, $1)  /  (totalSupply * P)
///          при totalSupply = 0 покрытие = type(uint256).max («бесконечное»), уровень FULL.
///  УРОВНИ ВЫКУПА (определяются по покрытию ДО выкупа):
///          coverage >= 140%         -> FULL:      usd = tokens * P * 1,2 (с буфером)
///          115% <= coverage < 140%  -> STANDARD:  usd = tokens * P       (без буфера)
///          coverage < 115%          -> SUSPENDED: выкуп временно приостановлен (revert),
///                                       снимается автоматически при восстановлении покрытия.
///          Любой разрешённый выкуп не уменьшает покрытие оставшихся держателей:
///          (R - kV) / (L - V) >= R / L  <=>  k <= R / L, где k = 1,2 (FULL) или 1,0 (STANDARD).
///  ВЫКУП:  gross    = floor(usd / max(p, $1))               (одно округление; <= резерв стейбла в корзине)
///          fee      = ceil(gross * 0,3%), пользователю gross - fee
contract BasketVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Константы
    // ---------------------------------------------------------------------
    /// @notice Базис: 10 000 bps = 100%.
    uint256 public constant BPS = 10_000;
    /// @notice Комиссия минта и выкупа, 30 bps = 0,3%.
    uint256 public constant FEE_BPS = 30;
    /// @notice Буфер переколлатерализации, 2000 bps = 20%.
    uint256 public constant BUFFER_BPS = 2_000;
    /// @notice Максимальное отклонение рабочей цены от индекса, 300 bps = ±3%.
    uint256 public constant MAX_DRIFT_BPS = 300;
    /// @notice Порог депега стейбла, 500 bps = ±5% от $1 (границы включительно — ещё не депег).
    uint256 public constant DEPEG_BPS = 500;
    /// @notice День месяца (UTC), в который разрешено фиксировать индекс.
    uint256 public constant INDEX_UPDATE_DAY = 28;
    /// @notice Жёсткий лимит изменения индекса за одно обновление setIndex: ±11% от предыдущего
    ///         зафиксированного индекса корзины. Константа: owner не может её менять.
    uint256 public constant MAX_INDEX_CHANGE_BPS = 1_100;
    /// @notice Таймлок добавления нового стейбла.
    uint256 public constant STABLE_TIMELOCK = 9 days;
    /// @notice Нижняя граница параметра минимального минта ($50).
    uint256 public constant MIN_MINT_LOWER = 50e18;
    /// @notice Верхняя граница параметра минимального минта ($1000).
    uint256 public constant MIN_MINT_UPPER = 1_000e18;
    /// @notice $1 в 18 знаках.
    uint256 public constant ONE_USD = 1e18;
    /// @notice Порог полного выкупа с буфером (140%). Константа: owner не может её менять.
    uint256 public constant FULL_REDEEM_COVERAGE_BPS = 14_000;
    /// @notice Порог приостановки выкупа (115%). Ниже — выкуп приостановлен.
    uint256 public constant MIN_REDEEM_COVERAGE_BPS = 11_500;
    /// @notice Лимит газа на одно обращение к ценовому фиду (защита от DoS со стороны фида).
    uint256 public constant FEED_GAS_LIMIT = 100_000;
    /// @notice Максимальный сырой ответ фида, который считается валидным (защита от переполнения).
    uint256 public constant MAX_FEED_ANSWER = type(uint128).max;
    /// @notice Верхняя граница индекса и ручной цены стейбла ($1e18 в 18 знаках) — защита от переполнения
    ///         промежуточных произведений; на практике недостижима.
    uint256 public constant MAX_PRICE = 1e36;
    /// @notice Максимальная длительность одной паузы: по истечении пауза снимается сама (угроза T10).
    uint256 public constant MAX_PAUSE_DURATION = 30 days;
    /// @notice После окончания паузы (снятие или истечение) новая пауза возможна не раньше чем через этот срок:
    ///         гарантированное окно выхода для держателей.
    uint256 public constant PAUSE_COOLDOWN = 3 days;
    /// @notice Grace period после восстановления L2-секвенсора (рекомендация Chainlink — 3600 с).
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    /// @notice Задержка таймлока для параметров (фид, ручная цена, казна, guardian, фид секвенсора).
    uint256 public constant PARAM_DELAY = 2 days;
    /// @notice Задержка таймлока для ролей токенов (MINTER_ROLE / DEFAULT_ADMIN_ROLE): это право эмиссии.
    uint256 public constant ROLE_DELAY = 7 days;
    /// @notice Сколько времени после готовности (eta) операцию ещё можно исполнить; потом она протухает.
    uint256 public constant OP_EXPIRY = 14 days;

    // ---- v5: ограничитель минта (защита покрытия) ----
    /// @notice Длина окна часового лимита минта.
    uint256 public constant MINT_WINDOW = 1 hours;
    /// @notice Значения по умолчанию (выставляются в конструкторе): пол 150%, начало сужения 160%,
    ///         10% резерва в час, 5% резерва за блок.
    uint256 public constant DEFAULT_MINT_FLOOR_BPS = 15_000;
    uint256 public constant DEFAULT_MINT_TAPER_BPS = 16_000;
    uint256 public constant DEFAULT_MINT_HOUR_CAP_BPS = 1_000;
    uint256 public constant DEFAULT_MINT_BLOCK_CAP_BPS = 500;
    /// @notice Безопасные границы параметров (owner не может выйти за них даже через таймлок).
    ///         Пол не ниже порога полного выкупа 140%: минт не может перевести корзину в STANDARD.
    uint256 public constant MINT_FLOOR_MIN_BPS = 14_000;
    uint256 public constant MINT_FLOOR_MAX_BPS = 20_000;
    /// @notice Максимальная ширина зоны сужения (taper - floor).
    uint256 public constant MINT_TAPER_MAX_SPAN_BPS = 3_000;
    /// @notice Часовой лимит: от 1% до 50% резерва.
    uint256 public constant MINT_HOUR_CAP_MIN_BPS = 100;
    uint256 public constant MINT_HOUR_CAP_MAX_BPS = 5_000;
    /// @notice Лимит за блок: от 0,1% резерва и не больше часового.
    uint256 public constant MINT_BLOCK_CAP_MIN_BPS = 10;
    /// @notice v5.1 (M1): заморозка минта перед окном setIndex 28-го. По умолчанию 6 ч, максимум 2 дня.
    ///         Заморозка действует с (28-е 00:00 UTC − mintFreezeSec) до фиксации индекса этого месяца
    ///         (или до конца 28-го, если индекс в этом месяце не меняли). Выкуп не замораживается.
    uint256 public constant DEFAULT_MINT_FREEZE = 6 hours;
    uint256 public constant MAX_MINT_FREEZE = 2 days;

    /// @notice Уровень выкупа корзины.
    enum RedeemTier {
        Suspended, // покрытие < 115%
        Standard, // 115% <= покрытие < 140%: выкуп без буфера
        Full // покрытие >= 140%: выкуп вместе с буфером
    }

    /// @notice Котировка выкупа для сайта (view, до транзакции).
    struct RedeemQuote {
        RedeemTier tier; // текущий уровень
        uint256 coverageBps; // текущее покрытие корзины, bps (12000 = 120%)
        uint256 payoutNow; // сколько пользователь получит сейчас (в стейбле, после комиссии); 0 если SUSPENDED
        uint256 feeNow; // комиссия при выкупе сейчас
        uint256 payoutWithBuffer; // сколько получил бы при уровне FULL (в стейбле, после комиссии)
        uint256 reserveAvailable; // резерв этого стейбла в корзине
        bool executableNow; // пройдёт ли выкуп сейчас: не пауза, не депег, не SUSPENDED, хватает резерва
    }

    /// @dev Данные операции минта/выкупа для события (memory-структура — обход лимита стека без via_ir).
    struct OpLog {
        uint256 stableAmount; // mint: фактически получено; redeem: выплачено пользователю
        uint256 fee;
        uint256 tokens; // mint: выпущено; redeem: сожжено
        uint256 stablePrice;
        RedeemTier tier; // уровень по покрытию ДО операции
        uint256 coverageBefore;
        uint256 coverageAfter;
    }

    // ---------------------------------------------------------------------
    // Хранилище
    // ---------------------------------------------------------------------
    /// @notice Параметры корзины.
    struct Basket {
        BasketToken token;
        uint256 index; // последний зафиксированный (28-го) индекс
        uint256 workingPrice; // рабочая цена, |workingPrice - index| <= 3% index
        uint256 lastIndexMonthKey; // год*12+месяц последнего setIndex (type(uint256).max = ещё не было)
        uint64 lastIndexTimestamp;
        bool exists;
    }

    /// @notice Параметры стейбла.
    struct Stable {
        bool enabled;
        uint8 decimals;
        IAggregatorV3 feed; // может быть address(0) — тогда только ручная цена
        uint256 manualPrice; // 18 знаков, fallback
        uint256 maxFeedStaleness; // сек; если фид старее — берём ручную цену
    }

    /// @notice Заявка на добавление стейбла (таймлок).
    struct PendingStable {
        uint64 executeAfter;
        IAggregatorV3 feed;
        uint256 maxFeedStaleness;
    }

    /// @notice Реестр корзин по basketId.
    mapping(uint256 basketId => Basket) public baskets;
    /// @notice Список зарегистрированных basketId.
    uint256[] public basketIds;
    /// @notice Токен уже привязан к какой-либо корзине (один токен — одна корзина).
    mapping(address token => bool) public tokenRegistered;

    /// @notice Параметры стейблов.
    mapping(address stable => Stable) public stables;
    /// @notice Список включённых стейблов.
    address[] public stableList;
    /// @notice Заявки на добавление стейблов.
    mapping(address stable => PendingStable) public pendingStables;

    /// @notice Резерв залога: корзина => стейбл => сумма (в единицах стейбла).
    mapping(uint256 basketId => mapping(address stable => uint256)) public reserves;

    /// @notice Последний известный уровень выкупа корзины (для событий CoverageTierChanged).
    mapping(uint256 basketId => RedeemTier) public lastTier;

    /// @notice Последний известный статус депега стейбла (для событий StableDepegStatusChanged).
    ///         Обновляется в транзакциях, которые читают цену стейбла: mint/redeem/topUp, setManualPrice,
    ///         setStableFeed, pokeTier, pokeStable. Сам запрет минта/выкупа от него не зависит —
    ///         он проверяется по текущей цене в каждой транзакции.
    mapping(address stable => bool) public lastDepegged;

    /// @notice Казна, получающая комиссии.
    address public feeRecipient;
    /// @notice Минимальный минт, USD 18 знаков.
    uint256 public minMintUsd;

    /// @notice Адрес, который может только поставить паузу (быстрая реакция). Снимает паузу только owner.
    address public guardian;
    /// @notice Момент, когда текущая (или последняя) пауза заканчивается/закончилась.
    uint64 public pausedUntil;
    /// @notice Chainlink L2 Sequencer Uptime Feed (address(0) — проверка отключена, например в тестнете).
    address public sequencerUptimeFeed;
    /// @notice Таймлок: id операции => момент, с которого её можно исполнить (0 — нет заявки).
    mapping(bytes32 id => uint256 eta) public opEta;

    /// @notice v5: параметры ограничителя минта (общие для всех корзин), bps.
    struct MintLimits {
        uint32 floorBps; // минт откатывается, если покрытие ПОСЛЕ него < floor
        uint32 taperBps; // при покрытии ДО минта в [floor, taper) лимиты линейно сужаются до 0
        uint32 hourCapBps; // лимит минта за окно MINT_WINDOW, доля резерва корзины
        uint32 blockCapBps; // лимит минта за блок, доля резерва корзины
    }

    /// @notice v5: учёт использованных лимитов корзины (USD 18 знаков, оценка нетто-взноса по min(p,$1)).
    struct MintWindow {
        uint64 window; // номер окна: block.timestamp / MINT_WINDOW
        uint64 blockNumber;
        uint256 windowUsedUsd;
        uint256 blockUsedUsd;
        uint256 prevWindowUsedUsd; // v5.1: использовано в предыдущем окне (скользящее окно)
    }

    /// @notice v5: текущие параметры ограничителя минта.
    MintLimits public mintLimits;
    /// @notice v5: учёт лимитов по корзинам.
    mapping(uint256 basketId => MintWindow) public mintWindows;
    /// @notice v5.1 (M1): длительность заморозки минта перед 28-м числом, с (0 — выключено). Таймлок PARAM_DELAY.
    uint256 public mintFreezeSec;

    // ---------------------------------------------------------------------
    // События
    // ---------------------------------------------------------------------
    /// @notice Зарегистрирована корзина.
    /// @param basketId корзина
    /// @param token токен корзины
    /// @param initialIndex стартовый индекс (он же рабочая цена), USD 18 знаков
    /// @param initialTier стартовый уровень (при нулевом supply — Full)
    event BasketAdded(uint256 indexed basketId, address indexed token, uint256 initialIndex, RedeemTier initialTier);
    /// @notice Зафиксирован новый индекс (28-го). Рабочая цена сбрасывается на новый индекс.
    /// @param oldIndex прежний индекс
    /// @param newIndex новый индекс
    /// @param oldWorkingPrice рабочая цена до сброса
    /// @param year год (UTC)
    /// @param month месяц (UTC, 1–12)
    /// @param timestamp время фиксации (block.timestamp)
    event IndexUpdated(
        uint256 indexed basketId,
        uint256 oldIndex,
        uint256 newIndex,
        uint256 oldWorkingPrice,
        uint256 year,
        uint256 month,
        uint256 timestamp
    );
    /// @notice Изменена рабочая цена (в пределах ±3% от индекса).
    /// @param oldPrice прежняя рабочая цена
    /// @param newPrice новая рабочая цена
    /// @param index текущий индекс, относительно которого проверен коридор
    event WorkingPriceUpdated(uint256 indexed basketId, uint256 oldPrice, uint256 newPrice, uint256 index);
    /// @notice Предложен новый стейбл (таймлок 9 дней).
    /// @param decimals decimals токена
    /// @param feed фид (или address(0))
    /// @param maxFeedStaleness допустимый возраст ответа фида, сек
    /// @param executeAfter время, начиная с которого можно вызвать executeStable (eta)
    /// @param previousExecuteAfter eta прежней заявки на этот адрес (0, если заявки не было) — повторное
    ///        предложение перезапускает таймлок
    event StableProposed(
        address indexed stable,
        uint8 decimals,
        address indexed feed,
        uint256 maxFeedStaleness,
        uint256 executeAfter,
        uint256 previousExecuteAfter
    );
    /// @notice Заявка на стейбл отменена.
    /// @param executeAfter eta отменённой заявки
    event StableProposalCancelled(address indexed stable, uint256 executeAfter);
    /// @notice Стейбл включён (в конструкторе — USDT/USDC, далее — только через executeStable).
    /// @param viaTimelock true — через таймлок, false — в конструкторе
    event StableAdded(
        address indexed stable, uint8 decimals, address indexed feed, uint256 maxFeedStaleness, bool viaTimelock
    );
    /// @notice Изменён фид стейбла или его допустимая давность.
    event StableFeedUpdated(
        address indexed stable, address oldFeed, address newFeed, uint256 oldMaxStaleness, uint256 newMaxStaleness
    );
    /// @notice Изменена ручная цена стейбла.
    event ManualPriceUpdated(address indexed stable, uint256 oldPrice, uint256 newPrice);
    /// @notice Стейбл вошёл в депег (цена вне $0,95–$1,05) или вышел из него. Выпускается, когда переход
    ///         обнаружен в транзакции (ручная цена, смена фида, poke, успешные mint/redeem/topUp).
    /// @param depegged true — вошёл в депег, false — вернулся в коридор
    /// @param price цена стейбла, по которой обнаружен переход (18 знаков)
    event StableDepegStatusChanged(address indexed stable, bool depegged, uint256 price);
    /// @notice Изменён минимальный минт (в конструкторе oldValue = 0).
    event MinMintUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Изменена казна (в конструкторе oldRecipient = address(0)).
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Сменён guardian паузы (address(0) — отозван).
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    /// @notice Пауза поставлена до `until` (по истечении снимается сама).
    event PauseWindow(address indexed by, uint256 until);
    /// @notice Сменён фид L2 Sequencer Uptime (address(0) — проверка отключена).
    event SequencerUptimeFeedUpdated(address indexed oldFeed, address indexed newFeed);
    /// @notice Админская операция поставлена в таймлок.
    /// @param id keccak256(abi.encode(data, salt))
    /// @param selector селектор вызываемой функции
    /// @param data полный calldata вызова
    /// @param salt соль
    /// @param eta с какого момента можно исполнить (до eta + OP_EXPIRY)
    event OpScheduled(bytes32 indexed id, bytes4 indexed selector, bytes data, bytes32 salt, uint256 eta);
    /// @notice Операция из таймлока исполнена.
    event OpExecuted(bytes32 indexed id, bytes4 indexed selector);
    /// @notice Операция из таймлока отменена.
    event OpCancelled(bytes32 indexed id);
    /// @notice Через таймлок выдана/отозвана роль на токене корзины.
    event TokenRoleUpdated(address indexed token, bytes32 indexed role, address indexed account, bool granted);
    /// @notice Минт.
    /// @param stableIn фактически полученная сумма стейбла (до комиссии протокола)
    /// @param fee комиссия протокола в стейбле (ушла в казну)
    /// @param tokensOut выпущено токенов
    /// @param workingPrice рабочая цена токена
    /// @param stablePrice цена стейбла (фид или ручная), 18 знаков
    /// @param tier уровень выкупа до операции
    /// @param coverageBefore покрытие до операции, bps (type(uint256).max при нулевом supply)
    /// @param coverageAfter покрытие после операции, bps
    event Minted(
        uint256 indexed basketId,
        address indexed user,
        address indexed stable,
        uint256 stableIn,
        uint256 fee,
        uint256 tokensOut,
        uint256 workingPrice,
        uint256 stablePrice,
        RedeemTier tier,
        uint256 coverageBefore,
        uint256 coverageAfter
    );
    /// @notice Выкуп.
    /// @param tokensIn сожжено токенов
    /// @param stableOut выплачено пользователю (после комиссии); из резерва ушло stableOut + fee
    /// @param fee комиссия протокола в стейбле
    /// @param tier уровень, по которому прошёл выкуп (по покрытию ДО выкупа)
    event Redeemed(
        uint256 indexed basketId,
        address indexed user,
        address indexed stable,
        uint256 tokensIn,
        uint256 stableOut,
        uint256 fee,
        uint256 workingPrice,
        uint256 stablePrice,
        RedeemTier tier,
        uint256 coverageBefore,
        uint256 coverageAfter
    );
    /// @notice Смена уровня выкупа. На него подписываются сайт/бот: например, newTier = Full
    ///         означает «теперь можно выкупить вместе с буфером». Выпускается только при фактической смене.
    event CoverageTierChanged(
        uint256 indexed basketId, RedeemTier indexed oldTier, RedeemTier indexed newTier, uint256 coverageBps
    );
    /// @notice Резерв пополнен без минта.
    /// @param amount фактически полученная сумма
    event ReserveToppedUp(
        uint256 indexed basketId,
        address indexed from,
        address indexed stable,
        uint256 amount,
        uint256 coverageBefore,
        uint256 coverageAfter
    );

    /// @notice v5: изменены параметры ограничителя минта.
    event MintLimitsUpdated(uint256 floorBps, uint256 taperBps, uint256 hourCapBps, uint256 blockCapBps);
    /// @notice v5.1: изменена длительность заморозки минта перед setIndex.
    event MintFreezeUpdated(uint256 oldSec, uint256 newSec);

    // ---------------------------------------------------------------------
    // Ошибки
    // ---------------------------------------------------------------------
    error ZeroAddress();
    error ZeroAmount();
    error UnknownBasket(uint256 basketId);
    error BasketExists(uint256 basketId);
    error TokenAlreadyRegistered(address token);
    error StableNotEnabled(address stable);
    error StableAlreadyEnabled(address stable);
    error StableDepegged(address stable, uint256 price);
    error NoPendingStable(address stable);
    error TimelockNotExpired(uint256 executeAfter);
    error UnsupportedDecimals(uint8 decimals);
    error NotIndexDay(uint256 day);
    error IndexAlreadyUpdatedThisMonth();
    error PriceOutOfBand(uint256 price, uint256 index);
    error InvalidPrice();
    error IndexChangeTooLarge(
        uint256 basketId, uint256 oldIndex, uint256 newIndex, uint256 minAllowed, uint256 maxAllowed
    );
    error InvalidFeeRecipient(address recipient);
    error MinMintOutOfRange(uint256 value);
    error BelowMinMint(uint256 usdValue, uint256 minMintUsd);
    error Slippage(uint256 actual, uint256 minimum);
    error InsufficientReserve(uint256 needed, uint256 available);
    error RenounceDisabled();
    error RedemptionSuspended(uint256 basketId, uint256 coverageBps, uint256 minCoverageBps);
    error OnlyTimelock();
    error NotTimelockable(bytes4 selector);
    error OpAlreadyScheduled(bytes32 id);
    error OpNotScheduled(bytes32 id);
    error OpNotReady(bytes32 id, uint256 eta);
    error OpExpired(bytes32 id, uint256 deadline);
    error NotOwnerOrGuardian(address caller);
    error PauseCooldown(uint256 allowedAt);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince);
    error SequencerFeedInvalid();
    error FeedUnavailable(address stable);
    error TokenNotRegistered(address token);
    // v5
    error MintLimitsOutOfRange(uint256 floorBps, uint256 taperBps, uint256 hourCapBps, uint256 blockCapBps);
    error MintCoverageFloor(uint256 basketId, uint256 coverageAfterBps, uint256 floorBps);
    error MintWindowCapExceeded(uint256 basketId, uint256 usdIn, uint256 remainingUsd);
    error MintBlockCapExceeded(uint256 basketId, uint256 usdIn, uint256 remainingUsd);
    // v5.1
    error MintFrozenBeforeIndex(uint256 basketId, uint256 year, uint256 month);
    error MintFreezeOutOfRange(uint256 sec);
    error GenesisTopUpRequired(uint256 basketId, uint256 missingUsd);

    /// @dev Функция вызывается только через таймлок: scheduleOp → (задержка) → executeOp.
    modifier onlyTimelock() {
        _onlyTimelock();
        _;
    }

    function _onlyTimelock() internal view {
        if (msg.sender != address(this)) revert OnlyTimelock();
    }

    // ---------------------------------------------------------------------
    // Конструктор
    // ---------------------------------------------------------------------
    /// @param owner_ владелец — Safe 2-of-3: оракул, пауза, таймлок параметров
    /// @param feeRecipient_ казна для комиссий
    /// @param usdt адрес USDT (добавляется сразу, без таймлока)
    /// @param usdc адрес USDC (добавляется сразу, без таймлока)
    /// @param minMintUsd_ минимальный минт, USD 18 знаков, в диапазоне [$50, $1000]
    /// @param guardian_ guardian паузы (address(0) — нет)
    /// @param sequencerUptimeFeed_ Chainlink L2 Sequencer Uptime Feed (address(0) — проверка отключена)
    // slither-disable-start missing-zero-check — проверка в _validateFeeRecipient
    // forge-lint: disable-start(missing-zero-check) — fee: _validateFeeRecipient; guardian/фид: 0 = выключено
    constructor(
        address owner_,
        address feeRecipient_,
        address usdt,
        address usdc,
        uint256 minMintUsd_,
        address guardian_,
        address sequencerUptimeFeed_
    ) Ownable(owner_) {
        _validateFeeRecipient(feeRecipient_);
        if (minMintUsd_ < MIN_MINT_LOWER || minMintUsd_ > MIN_MINT_UPPER) revert MinMintOutOfRange(minMintUsd_);
        feeRecipient = feeRecipient_;
        minMintUsd = minMintUsd_;
        emit FeeRecipientUpdated(address(0), feeRecipient_);
        emit MinMintUpdated(0, minMintUsd_);
        guardian = guardian_;
        sequencerUptimeFeed = sequencerUptimeFeed_;
        emit GuardianUpdated(address(0), guardian_);
        emit SequencerUptimeFeedUpdated(address(0), sequencerUptimeFeed_);
        _setMintLimits(
            DEFAULT_MINT_FLOOR_BPS, DEFAULT_MINT_TAPER_BPS, DEFAULT_MINT_HOUR_CAP_BPS, DEFAULT_MINT_BLOCK_CAP_BPS
        );
        mintFreezeSec = DEFAULT_MINT_FREEZE;
        emit MintFreezeUpdated(0, DEFAULT_MINT_FREEZE);
        // forge-lint: disable-end(missing-zero-check)
        _addStable(usdt, IAggregatorV3(address(0)), 0, false);
        _addStable(usdc, IAggregatorV3(address(0)), 0, false);
    }

    // slither-disable-end missing-zero-check

    // ---------------------------------------------------------------------
    // Реестр корзин
    // ---------------------------------------------------------------------
    /// @notice Регистрирует корзину basketId => токен + стартовый индекс.
    /// @dev Vault должен иметь MINTER_ROLE на токене. Стартовый индекс задаётся без правила 28-го числа.
    ///      Один токен можно привязать только к одной корзине (иначе общий totalSupply позволил бы
    ///      выкупать токены одной корзины за резервы другой).
    /// @param basketId идентификатор корзины
    /// @param token ERC20-токен корзины
    /// @param initialIndex стартовый индекс, USD 18 знаков
    function addBasket(uint256 basketId, BasketToken token, uint256 initialIndex) external onlyOwner {
        if (address(token) == address(0)) revert ZeroAddress();
        if (initialIndex == 0 || initialIndex > MAX_PRICE) revert InvalidPrice();
        if (baskets[basketId].exists) revert BasketExists(basketId);
        if (tokenRegistered[address(token)]) revert TokenAlreadyRegistered(address(token));
        tokenRegistered[address(token)] = true;
        baskets[basketId] = Basket({
            token: token,
            index: initialIndex,
            workingPrice: initialIndex,
            lastIndexMonthKey: type(uint256).max,
            // forge-lint: disable-next-line(unsafe-typecast)
            lastIndexTimestamp: uint64(block.timestamp), // timestamp помещается в uint64 до 2^64 с
            exists: true
        });
        basketIds.push(basketId);
        RedeemTier initialTier = _tierOf(_coverageBps(basketId));
        lastTier[basketId] = initialTier;
        // forge-lint: disable-next-line(reentrancy-events) — внешний вызов только view totalSupply() доверенного токена
        emit BasketAdded(basketId, address(token), initialIndex, initialTier);
    }

    // ---------------------------------------------------------------------
    // Оракул (только owner)
    // ---------------------------------------------------------------------
    /// @notice Фиксирует новый индекс. Разрешено только 28-го числа (UTC) и один раз в календарный месяц.
    ///         Новый индекс — не дальше ±11% от предыдущего зафиксированного индекса (границы включительно;
    ///         границы округляются в сторону строгости: min = ceil(old×0,89), max = floor(old×1,11)).
    ///         Рабочая цена сбрасывается на новый индекс. Отказ (revert) не расходует попытку месяца.
    /// @param basketId корзина
    /// @param newIndex новый индекс, USD 18 знаков (0 < newIndex <= MAX_PRICE)
    function setIndex(uint256 basketId, uint256 newIndex) external onlyOwner {
        Basket storage b = _basket(basketId);
        if (newIndex == 0 || newIndex > MAX_PRICE) revert InvalidPrice();
        (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(block.timestamp);
        if (d != INDEX_UPDATE_DAY) revert NotIndexDay(d);
        uint256 key = y * 12 + (m - 1);
        // slither-disable-next-line incorrect-equality — сравнение ключей месяца, не балансов: строгое равенство корректно
        if (b.lastIndexMonthKey == key) revert IndexAlreadyUpdatedThisMonth();
        uint256 oldIndex = b.index;
        (uint256 minAllowed, uint256 maxAllowed) = _indexBounds(oldIndex);
        if (newIndex < minAllowed || newIndex > maxAllowed) {
            revert IndexChangeTooLarge(basketId, oldIndex, newIndex, minAllowed, maxAllowed);
        }
        uint256 oldWorking = b.workingPrice;
        b.index = newIndex;
        b.workingPrice = newIndex;
        b.lastIndexMonthKey = key;
        // forge-lint: disable-next-line(unsafe-typecast)
        b.lastIndexTimestamp = uint64(block.timestamp);
        // Ложное срабатывание линтера: в setIndex нет внешних вызовов (DateLib, _indexBounds/Math.mulDiv —
        // internal/pure; revert с кастомной ошибкой — не вызов).
        // forge-lint: disable-next-line(reentrancy-events)
        emit IndexUpdated(basketId, oldIndex, newIndex, oldWorking, y, m, block.timestamp);
        _syncTier(basketId);
    }

    /// @notice Промежуточная рабочая цена между обновлениями: в пределах ±3% от индекса (границы включительно).
    /// @param basketId корзина
    /// @param price новая рабочая цена, USD 18 знаков
    function setWorkingPrice(uint256 basketId, uint256 price) external onlyOwner {
        Basket storage b = _basket(basketId);
        uint256 band = (b.index * MAX_DRIFT_BPS) / BPS;
        if (price < b.index - band || price > b.index + band) revert PriceOutOfBand(price, b.index);
        uint256 oldPrice = b.workingPrice;
        b.workingPrice = price;
        emit WorkingPriceUpdated(basketId, oldPrice, price, b.index);
        _syncTier(basketId);
    }

    // ---------------------------------------------------------------------
    // Стейблкоины
    // ---------------------------------------------------------------------
    /// @notice Шаг 1: предложить новый стейбл. Исполнение — не раньше чем через 9 дней.
    ///         Повторное предложение того же адреса перезапускает таймлок.
    /// @param stable адрес ERC20-стейбла (decimals <= 18)
    /// @param feed Chainlink-совместимый фид (или address(0))
    /// @param maxFeedStaleness допустимый возраст ответа фида, сек
    function proposeStable(address stable, IAggregatorV3 feed, uint256 maxFeedStaleness) external onlyOwner {
        if (stable == address(0)) revert ZeroAddress();
        if (stables[stable].enabled) revert StableAlreadyEnabled(stable);
        uint8 dec = IERC20Metadata(stable).decimals(); // ранняя проверка, чтобы execute не упал через 9 дней
        if (dec > 18) revert UnsupportedDecimals(dec);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 executeAfter = uint64(block.timestamp + STABLE_TIMELOCK);
        uint256 previous = pendingStables[stable].executeAfter;
        pendingStables[stable] = PendingStable(executeAfter, feed, maxFeedStaleness);
        emit StableProposed(stable, dec, address(feed), maxFeedStaleness, executeAfter, previous);
    }

    /// @notice Шаг 2: включить предложенный стейбл после истечения таймлока.
    /// @param stable адрес ранее предложенного стейбла
    function executeStable(address stable) external onlyOwner {
        PendingStable memory p = pendingStables[stable];
        if (p.executeAfter == 0) revert NoPendingStable(stable);
        // forge-lint: disable-next-line(block-timestamp) — таймлок 9 дней, сдвиг времени валидатором (секунды) несущественен
        if (block.timestamp < p.executeAfter) revert TimelockNotExpired(p.executeAfter);
        delete pendingStables[stable];
        _addStable(stable, p.feed, p.maxFeedStaleness, true);
        _syncDepeg(stable, _price(stables[stable]));
    }

    /// @notice Отменить заявку на стейбл.
    /// @param stable адрес предложенного стейбла
    function cancelStable(address stable) external onlyOwner {
        uint256 eta = pendingStables[stable].executeAfter;
        if (eta == 0) revert NoPendingStable(stable);
        delete pendingStables[stable];
        emit StableProposalCancelled(stable, eta);
    }

    /// @notice Ручная цена стейбла. ТАЙМЛОК PARAM_DELAY (2 дня). В mint/redeem используется только у стейбла
    ///         без фида; у стейбла с фидом — лишь во view/оценке покрытия, когда фид невалиден.
    /// @param stable включённый стейбл
    /// @param price цена, USD 18 знаков (0 < price <= MAX_PRICE)
    function setManualPrice(address stable, uint256 price) external onlyTimelock {
        if (!stables[stable].enabled) revert StableNotEnabled(stable);
        if (price == 0 || price > MAX_PRICE) revert InvalidPrice();
        uint256 oldPrice = stables[stable].manualPrice;
        stables[stable].manualPrice = price;
        emit ManualPriceUpdated(stable, oldPrice, price);
        _syncDepeg(stable, _price(stables[stable]));
        _syncAllTiers();
    }

    /// @notice Подключить/сменить Chainlink-совместимый фид (address(0) — отключить фид). ТАЙМЛОК PARAM_DELAY.
    /// @param stable включённый стейбл
    /// @param feed фид
    /// @param maxFeedStaleness допустимый возраст ответа фида, сек
    function setStableFeed(address stable, IAggregatorV3 feed, uint256 maxFeedStaleness) external onlyTimelock {
        if (!stables[stable].enabled) revert StableNotEnabled(stable);
        Stable storage s = stables[stable];
        emit StableFeedUpdated(stable, address(s.feed), address(feed), s.maxFeedStaleness, maxFeedStaleness);
        s.feed = feed;
        s.maxFeedStaleness = maxFeedStaleness;
        _syncDepeg(stable, _price(s));
        _syncAllTiers();
    }

    // ---------------------------------------------------------------------
    // Параметры
    // ---------------------------------------------------------------------
    /// @notice Изменить минимальный минт (в пределах $50–$1000 включительно).
    /// @param newMin новое значение, USD 18 знаков
    function setMinMintUsd(uint256 newMin) external onlyOwner {
        if (newMin < MIN_MINT_LOWER || newMin > MIN_MINT_UPPER) revert MinMintOutOfRange(newMin);
        emit MinMintUpdated(minMintUsd, newMin);
        minMintUsd = newMin;
    }

    /// @notice Изменить казну для комиссий (не нулевой адрес и не сам Vault). ТАЙМЛОК PARAM_DELAY.
    /// @param newRecipient новый адрес казны
    // slither-disable-start missing-zero-check — проверка в _validateFeeRecipient
    // forge-lint: disable-next-line(missing-zero-check) — проверка в _validateFeeRecipient
    function setFeeRecipient(address newRecipient) external onlyTimelock {
        _validateFeeRecipient(newRecipient);
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    // slither-disable-end missing-zero-check

    /// @notice Аварийная пауза: останавливает весь минт и выкуп. Может owner или guardian.
    ///         Пауза длится не дольше MAX_PAUSE_DURATION и снимается сама; продлить нельзя. Новая пауза —
    ///         не раньше чем через PAUSE_COOLDOWN после окончания предыдущей (окно выхода для держателей).
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian(msg.sender);
        _pause(); // whenNotPaused: во время активной паузы — EnforcedPause (продлить нельзя)
        uint256 last = pausedUntil;
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < last + PAUSE_COOLDOWN) revert PauseCooldown(last + PAUSE_COOLDOWN);
        uint256 until = block.timestamp + MAX_PAUSE_DURATION;
        // forge-lint: disable-next-line(unsafe-typecast)
        pausedUntil = uint64(until);
        emit PauseWindow(msg.sender, until);
    }

    /// @notice Снять аварийную паузу досрочно. Только owner (guardian снять паузу не может).
    function unpause() external onlyOwner {
        _unpause();
        // forge-lint: disable-next-line(unsafe-typecast)
        pausedUntil = uint64(block.timestamp);
    }

    /// @notice Пауза активна: поставлена и ещё не истекла.
    /// @return true, если mint/redeem сейчас остановлены паузой
    function paused() public view override returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return super.paused() && block.timestamp < pausedUntil;
    }

    /// @notice Назначить guardian паузы. ТАЙМЛОК PARAM_DELAY.
    /// @param newGuardian новый guardian (address(0) — без guardian)
    // slither-disable-start missing-zero-check — address(0) у guardian и фида секвенсора означает «выключено»
    // forge-lint: disable-next-line(missing-zero-check) — address(0) = без guardian
    function setGuardian(address newGuardian) external onlyTimelock {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Немедленно отозвать guardian (только уменьшает права, поэтому без таймлока).
    function revokeGuardian() external onlyOwner {
        emit GuardianUpdated(guardian, address(0));
        guardian = address(0);
    }

    /// @notice Подключить/отключить Chainlink L2 Sequencer Uptime Feed. ТАЙМЛОК PARAM_DELAY.
    /// @param feed адрес фида (address(0) — отключить проверку)
    // forge-lint: disable-next-line(missing-zero-check) — address(0) = проверка выключена
    function setSequencerUptimeFeed(address feed) external onlyTimelock {
        if (feed != address(0)) {
            // v5.1: новый фид обязан отвечать в формате latestRoundData (EOA/чужой контракт — отказ)
            (bool ok, uint256 len,) = _staticcallWords5(feed, IAggregatorV3.latestRoundData.selector);
            if (!ok || len < 160) revert SequencerFeedInvalid();
        }
        // forge-lint: disable-next-line(reentrancy-events) — выше только staticcall (view)
        emit SequencerUptimeFeedUpdated(sequencerUptimeFeed, feed);
        sequencerUptimeFeed = feed;
    }

    // slither-disable-end missing-zero-check

    /// @notice Выдать или отозвать роль на токене корзины (Vault должен быть его админом). ТАЙМЛОК ROLE_DELAY.
    /// @param token зарегистрированный токен корзины
    /// @param role роль (например MINTER_ROLE или DEFAULT_ADMIN_ROLE)
    /// @param account адрес
    /// @param grant true — выдать, false — отозвать
    function setTokenRole(address token, bytes32 role, address account, bool grant) external onlyTimelock {
        if (!tokenRegistered[token]) revert TokenNotRegistered(token);
        emit TokenRoleUpdated(token, role, account, grant);
        if (grant) IAccessControl(token).grantRole(role, account);
        else IAccessControl(token).revokeRole(role, account);
    }

    /// @notice v5: изменить параметры ограничителя минта. Только через таймлок (PARAM_DELAY = 2 дня),
    ///         только в безопасных границах (см. MINT_*_BPS).
    /// @param floorBps пол покрытия после минта, [140%, 200%]
    /// @param taperBps начало зоны сужения, [floor, floor + 30%] (taper == floor — без сужения)
    /// @param hourCapBps лимит за окно, [1%, 50%] резерва
    /// @param blockCapBps лимит за блок, [0,1%, hourCap] резерва
    function setMintLimits(uint256 floorBps, uint256 taperBps, uint256 hourCapBps, uint256 blockCapBps)
        external
        onlyTimelock
    {
        _setMintLimits(floorBps, taperBps, hourCapBps, blockCapBps);
    }

    /// @notice v5.1 (M1): длительность заморозки минта перед setIndex, [0, 2 дня]. Только через таймлок.
    /// @param sec секунды до 28-го 00:00 UTC, с которых минт закрыт (0 — выключить)
    function setMintFreeze(uint256 sec) external onlyTimelock {
        if (sec > MAX_MINT_FREEZE) revert MintFreezeOutOfRange(sec);
        emit MintFreezeUpdated(mintFreezeSec, sec);
        mintFreezeSec = sec;
    }

    /// @notice v5.1 (M1): закрыт ли сейчас минт корзины из-за предстоящей/незавершённой фиксации индекса.
    /// @param basketId корзина
    /// @return frozen true — минт откатится MintFrozenBeforeIndex
    function isMintFrozen(uint256 basketId) public view returns (bool frozen) {
        (frozen,,) = _mintFreeze(baskets[basketId]);
    }

    function _mintFreeze(Basket storage b) internal view returns (bool, uint256, uint256) {
        uint256 f = mintFreezeSec;
        if (f == 0) return (false, 0, 0);
        (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(block.timestamp);
        if (d != INDEX_UPDATE_DAY) {
            (y, m, d) = DateLib.timestampToDate(block.timestamp + f);
            if (d != INDEX_UPDATE_DAY) return (false, 0, 0);
        }
        // slither-disable-next-line incorrect-equality — сравнение ключей месяца
        if (b.lastIndexMonthKey == y * 12 + (m - 1)) return (false, 0, 0); // индекс этого месяца уже зафиксирован
        return (true, y, m);
    }

    function _setMintLimits(uint256 floorBps, uint256 taperBps, uint256 hourCapBps, uint256 blockCapBps) internal {
        if (
            floorBps < MINT_FLOOR_MIN_BPS || floorBps > MINT_FLOOR_MAX_BPS || taperBps < floorBps
                || taperBps > floorBps + MINT_TAPER_MAX_SPAN_BPS || hourCapBps < MINT_HOUR_CAP_MIN_BPS
                || hourCapBps > MINT_HOUR_CAP_MAX_BPS || blockCapBps < MINT_BLOCK_CAP_MIN_BPS
                || blockCapBps > hourCapBps
        ) revert MintLimitsOutOfRange(floorBps, taperBps, hourCapBps, blockCapBps);
        // Границы гарантируют, что все значения <= 23 000 и помещаются в uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        mintLimits = MintLimits(uint32(floorBps), uint32(taperBps), uint32(hourCapBps), uint32(blockCapBps));
        emit MintLimitsUpdated(floorBps, taperBps, hourCapBps, blockCapBps);
    }

    /// @notice v5: сколько ещё можно заминтить в корзину сейчас (USD 18 знаков, нетто после комиссии,
    ///         по min(p,$1)) с учётом окна, блока и сужения. Пол покрытия после минта проверяется отдельно.
    /// @param basketId корзина
    /// @return windowRemainingUsd остаток лимита окна
    /// @return blockRemainingUsd остаток лимита блока
    function mintCapacity(uint256 basketId)
        external
        view
        returns (uint256 windowRemainingUsd, uint256 blockRemainingUsd)
    {
        Basket storage b = _basket(basketId);
        if (b.token.totalSupply() == 0) return (type(uint256).max, type(uint256).max);
        (uint256 wCap, uint256 bCap) = _mintCaps(basketId, _coverageBps(basketId));
        MintWindow storage w = mintWindows[basketId];
        // slither-disable-next-line incorrect-equality — сравнение номеров окна/блока, не балансов
        uint256 win = block.timestamp / MINT_WINDOW;
        uint256 wUsed = 0;
        // forge-lint: disable-next-line(block-timestamp)
        // slither-disable-next-line incorrect-equality — номера окон, не балансы
        if (w.window == win) wUsed = w.windowUsedUsd + _carried(w.prevWindowUsedUsd);
        // slither-disable-next-line incorrect-equality — номера окон, не балансы
        else if (w.window + 1 == win) wUsed = _carried(w.windowUsedUsd);
        // slither-disable-next-line incorrect-equality — сравнение номеров окна/блока, не балансов
        uint256 bUsed = w.blockNumber == block.number ? w.blockUsedUsd : 0;
        windowRemainingUsd = wCap > wUsed ? wCap - wUsed : 0;
        blockRemainingUsd = bCap > bUsed ? bCap - bUsed : 0;
    }

    /// @dev Сколько USD (по min(p,$1)) не хватает в резерве, чтобы покрытие достигло пола (после минта).
    function _genesisMissingUsd(Basket storage b, uint256 basketId) internal view returns (uint256) {
        uint256 need = Math.mulDiv(
            Math.mulDiv(b.token.totalSupply(), b.workingPrice, 1e18, Math.Rounding.Ceil),
            mintLimits.floorBps,
            BPS,
            Math.Rounding.Ceil
        );
        uint256 have = _reserveUsd(basketId);
        return need > have ? need - have : 0;
    }

    /// @dev Лимиты окна и блока в USD: доля резерва * коэффициент сужения.
    function _mintCaps(uint256 basketId, uint256 covBefore) internal view returns (uint256 wCap, uint256 bCap) {
        MintLimits memory m = mintLimits;
        uint256 reserveUsd = _reserveUsd(basketId);
        uint256 f = BPS;
        if (covBefore < m.taperBps) {
            f = covBefore <= m.floorBps ? 0 : Math.mulDiv(covBefore - m.floorBps, BPS, m.taperBps - m.floorBps);
        }
        wCap = Math.mulDiv(reserveUsd, uint256(m.hourCapBps) * f, BPS * BPS);
        bCap = Math.mulDiv(reserveUsd, uint256(m.blockCapBps) * f, BPS * BPS);
    }

    /// @dev Вес предыдущего окна: prev * (оставшаяся доля текущего окна).
    function _carried(uint256 prev) internal view returns (uint256) {
        if (prev == 0) return 0;
        // forge-lint: disable-next-line(weak-prng) — не случайность: позиция внутри часового окна
        // slither-disable-next-line weak-prng
        // aderyn-ignore-next-line(weak-randomness)
        uint256 elapsed = block.timestamp % MINT_WINDOW;
        return Math.mulDiv(prev, MINT_WINDOW - elapsed, MINT_WINDOW, Math.Rounding.Ceil);
    }

    /// @dev Проверка и учёт лимитов окна/блока до минта. Первый минт в пустую корзину (supply == 0)
    ///      лимитами скорости не ограничен — мерить нечем; пол покрытия к нему всё равно применяется.
    function _consumeMintCaps(uint256 basketId, uint256 covBefore, uint256 usdIn) internal {
        // slither-disable-next-line incorrect-equality — пустая корзина (genesis), не баланс стейбла
        if (baskets[basketId].token.totalSupply() == 0) return;
        (uint256 wCap, uint256 bCap) = _mintCaps(basketId, covBefore);
        MintWindow storage w = mintWindows[basketId];
        uint64 win = uint64(block.timestamp / MINT_WINDOW);
        if (w.window != win) {
            // v5.1 (L-2): скользящее окно — предыдущее окно учитывается с линейно убывающим весом
            // slither-disable-next-line incorrect-equality — номера окон, не балансы
            w.prevWindowUsedUsd = w.window + 1 == win ? w.windowUsedUsd : 0;
            w.window = win;
            w.windowUsedUsd = 0;
        }
        uint64 bn = uint64(block.number);
        if (w.blockNumber != bn) {
            w.blockNumber = bn;
            w.blockUsedUsd = 0;
        }
        uint256 wNew = w.windowUsedUsd + usdIn;
        uint256 carried = _carried(w.prevWindowUsedUsd);
        if (wNew + carried > wCap) {
            uint256 usedEff = w.windowUsedUsd + carried;
            revert MintWindowCapExceeded(basketId, usdIn, wCap > usedEff ? wCap - usedEff : 0);
        }
        uint256 bNew = w.blockUsedUsd + usdIn;
        if (bNew > bCap) {
            revert MintBlockCapExceeded(basketId, usdIn, bCap > w.blockUsedUsd ? bCap - w.blockUsedUsd : 0);
        }
        w.windowUsedUsd = wNew;
        w.blockUsedUsd = bNew;
    }

    // ---------------------------------------------------------------------
    // Таймлок админских операций (schedule → задержка → execute)
    // ---------------------------------------------------------------------
    /// @notice Задержка для функции по селектору; 0 — функция не исполняется через таймлок.
    /// @param selector селектор
    /// @return delay задержка, с
    function opDelay(bytes4 selector) public pure returns (uint256 delay) {
        if (
            selector == this.setStableFeed.selector || selector == this.setManualPrice.selector
                || selector == this.setFeeRecipient.selector || selector == this.setGuardian.selector
                || selector == this.setSequencerUptimeFeed.selector || selector == this.setMintLimits.selector
                || selector == this.setMintFreeze.selector
        ) return PARAM_DELAY;
        if (selector == this.setTokenRole.selector) return ROLE_DELAY;
        return 0;
    }

    /// @notice id операции таймлока.
    /// @param data calldata вызова
    /// @param salt соль (позволяет поставить одинаковый вызов дважды)
    /// @return id идентификатор
    function opId(bytes calldata data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(data, salt));
    }

    /// @notice Шаг 1: поставить админскую операцию в таймлок. Только owner.
    /// @param data calldata вызова этого же контракта (например abi.encodeCall(vault.setFeeRecipient, (x)))
    /// @param salt соль
    /// @return id идентификатор операции
    function scheduleOp(bytes calldata data, bytes32 salt) external onlyOwner returns (bytes32 id) {
        bytes4 sel = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        uint256 delay = opDelay(sel);
        if (delay == 0) revert NotTimelockable(sel);
        id = opId(data, salt);
        uint256 prev = opEta[id];
        // v5.1 (L-3): протухшую заявку можно поставить заново с той же солью
        // forge-lint: disable-next-line(block-timestamp)
        if (prev != 0 && block.timestamp <= prev + OP_EXPIRY) revert OpAlreadyScheduled(id);
        uint256 eta = block.timestamp + delay;
        opEta[id] = eta;
        emit OpScheduled(id, sel, data, salt, eta);
    }

    /// @notice Шаг 2: исполнить операцию в окне [eta, eta + OP_EXPIRY]. Только owner.
    /// @param data тот же calldata
    /// @param salt та же соль
    /// @return result данные возврата
    function executeOp(bytes calldata data, bytes32 salt)
        external
        nonReentrant
        onlyOwner
        returns (bytes memory result)
    {
        bytes32 id = opId(data, salt);
        uint256 eta = opEta[id];
        if (eta == 0) revert OpNotScheduled(id);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < eta) revert OpNotReady(id, eta);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > eta + OP_EXPIRY) revert OpExpired(id, eta + OP_EXPIRY);
        delete opEta[id];
        emit OpExecuted(id, bytes4(data[:4]));
        result = Address.functionCall(address(this), data);
    }

    /// @notice Отменить операцию до исполнения. Только owner.
    /// @param id идентификатор
    function cancelOp(bytes32 id) external onlyOwner {
        if (opEta[id] == 0) revert OpNotScheduled(id);
        delete opEta[id];
        emit OpCancelled(id);
    }

    /// @notice Отказ от владения запрещён: без owner контракт нельзя снять с паузы и обновить индекс.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Минт / выкуп
    // ---------------------------------------------------------------------
    /// @notice Внести стейбл и получить токены корзины.
    /// @dev Порядок: проверки → перевод стейбла внутрь (нужен для учёта фактически полученной суммы
    ///      у токенов с комиссией за перевод) → эффекты → выплата комиссии и минт. Повторный вход
    ///      заблокирован nonReentrant.
    /// @param basketId корзина
    /// @param stable стейбл залога
    /// @param amount сумма стейбла
    /// @param minTokensOut защита от проскальзывания
    /// @return tokensOut выпущено токенов корзины
    function mint(uint256 basketId, address stable, uint256 amount, uint256 minTokensOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        Basket storage b = _basket(basketId);
        Stable storage s = _activeStable(stable);
        if (amount == 0) revert ZeroAmount();
        _checkSequencer();
        {
            (bool frozen, uint256 fy, uint256 fm) = _mintFreeze(b);
            if (frozen) revert MintFrozenBeforeIndex(basketId, fy, fm);
        }
        uint256 sPrice = _checkedPrice(stable, s);
        uint256 covBefore = _coverageBps(basketId);
        OpLog memory lg = OpLog({
            stableAmount: _pull(stable, amount),
            fee: 0,
            tokens: 0,
            stablePrice: sPrice,
            tier: _tierOf(covBefore),
            coverageBefore: covBefore,
            coverageAfter: 0
        });

        uint256 net;
        (lg.fee, net, tokensOut) = _quoteMint(b, s, lg.stablePrice, lg.stableAmount);
        // slither-disable-next-line incorrect-equality — защитная проверка нулевого выпуска, не баланс
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert Slippage(tokensOut, minTokensOut);
        lg.tokens = tokensOut;
        // v5: лимиты окна/блока считаются по резерву ДО минта
        _consumeMintCaps(
            basketId, covBefore, _toUsd(net, s.decimals, lg.stablePrice < ONE_USD ? lg.stablePrice : ONE_USD)
        );

        reserves[basketId][stable] += net;
        IERC20(stable).safeTransfer(feeRecipient, lg.fee); // fee > 0 всегда (ceil, received >= $50)
        // forge-lint: disable-next-line(reentrancy-no-eth) — функция под nonReentrant; токен — доверенный BasketToken
        b.token.mint(msg.sender, tokensOut);

        _syncDepeg(stable, lg.stablePrice);
        lg.coverageAfter = _coverageBps(basketId);
        // v5: пол покрытия после минта
        uint256 floorBps = mintLimits.floorBps;
        // slither-disable-next-line reentrancy-balance — coverageAfter считается после mint доверенного BasketToken под nonReentrant
        if (lg.coverageAfter < floorBps) {
            // slither-disable-next-line incorrect-equality — признак genesis (supply до минта был 0), не баланс
            if (covBefore == type(uint256).max) revert GenesisTopUpRequired(basketId, _genesisMissingUsd(b, basketId));
            revert MintCoverageFloor(basketId, lg.coverageAfter, floorBps);
        }
        _emitMinted(basketId, stable, b.workingPrice, lg);
        _syncTierAt(basketId, lg.coverageAfter);
    }

    /// @notice Пополнить резерв корзины без минта (токены не выпускаются). Повышает покрытие.
    /// @dev Разрешено любому адресу (решение Антона): пополнение только увеличивает обеспечение
    ///      держателей и не даёт пополнившему никаких прав. Работает и во время паузы.
    ///      Депегнутый стейбл принять можно — в покрытии он учитывается по min(p, $1).
    /// @param basketId корзина
    /// @param stable включённый стейбл
    /// @param amount сумма
    function topUpReserve(uint256 basketId, address stable, uint256 amount) external nonReentrant {
        _basket(basketId);
        Stable storage s = _activeStable(stable);
        if (amount == 0) revert ZeroAmount();
        uint256 covBefore = _coverageBps(basketId);
        uint256 received = _pull(stable, amount);
        reserves[basketId][stable] += received;
        _syncDepeg(stable, _price(s));
        uint256 covAfter = _coverageBps(basketId);
        // forge-lint: disable-next-line(reentrancy-events) — функция под nonReentrant
        emit ReserveToppedUp(basketId, msg.sender, stable, received, covBefore, covAfter);
        _syncTierAt(basketId, covAfter);
    }

    /// @notice Пересчитать уровень и при смене выпустить CoverageTierChanged. Может вызвать кто угодно
    ///         (нужно, когда покрытие изменилось без транзакции — например, из-за цены во внешнем фиде).
    /// @param basketId корзина
    ///         Также обновляет статус депега всех стейблов (StableDepegStatusChanged при переходе).
    function pokeTier(uint256 basketId) external nonReentrant {
        _basket(basketId);
        _syncAllDepeg();
        _syncTier(basketId);
    }

    /// @notice Обновить статус депега одного стейбла и уровни всех корзин (например, бот после движения фида).
    /// @param stable включённый стейбл
    function pokeStable(address stable) external nonReentrant {
        Stable storage s = _activeStable(stable);
        _syncDepeg(stable, _price(s));
        _syncAllTiers();
    }

    /// @notice Сжечь токены корзины и получить залог в выбранном стейбле.
    /// @dev Уровень (FULL/STANDARD/SUSPENDED) определяется по покрытию ДО выкупа.
    ///      Порядок checks-effects-interactions: резерв уменьшается и токены сжигаются до переводов.
    /// @param basketId корзина
    /// @param stable стейбл выплаты
    /// @param tokenAmount сколько токенов сжечь
    /// @param minStableOut защита от проскальзывания (в т.ч. от смены уровня между котировкой и исполнением)
    /// @return stableOut выплачено пользователю (после комиссии)
    function redeem(uint256 basketId, address stable, uint256 tokenAmount, uint256 minStableOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stableOut)
    {
        Basket storage b = _basket(basketId);
        if (tokenAmount == 0) revert ZeroAmount();
        _checkSequencer();
        OpLog memory lg;
        uint256 gross;
        (gross, lg) = _checkedRedeem(basketId, stable, tokenAmount);
        stableOut = gross - lg.fee;
        if (stableOut == 0) revert ZeroAmount();
        if (stableOut < minStableOut) revert Slippage(stableOut, minStableOut);
        lg.stableAmount = stableOut;
        lg.tokens = tokenAmount;

        reserves[basketId][stable] -= gross;
        // forge-lint: disable-next-line(reentrancy-no-eth) — функция под nonReentrant; эффекты (резерв) до вызова
        b.token.burn(msg.sender, tokenAmount);
        IERC20(stable).safeTransfer(feeRecipient, lg.fee); // fee > 0 (ceil, gross > 0)
        IERC20(stable).safeTransfer(msg.sender, stableOut);

        _syncDepeg(stable, lg.stablePrice);
        lg.coverageAfter = _coverageBps(basketId);
        _emitRedeemed(basketId, stable, b.workingPrice, lg);
        _syncTierAt(basketId, lg.coverageAfter);
    }

    // ---------------------------------------------------------------------
    // View
    // ---------------------------------------------------------------------
    /// @notice Текущая цена стейбла (фид, если свежий и валидный, иначе ручная цена), USD 18 знаков.
    /// @param stable включённый стейбл
    /// @return цена
    function stablePrice(address stable) public view returns (uint256) {
        Stable storage s = stables[stable];
        if (!s.enabled) revert StableNotEnabled(stable);
        return _price(s);
    }

    /// @notice Находится ли стейбл в депеге (цена вне [$0,95; $1,05]).
    /// @param stable включённый стейбл
    /// @return true — минт и выкуп в этом стейбле заблокированы
    function isDepegged(address stable) public view returns (bool) {
        return _isDepegged(stablePrice(stable));
    }

    /// @notice Сколько токенов выпустится при минте `amount` (без учёта комиссии самого токена за перевод).
    /// @dev Ревертит BelowMinMint так же, как mint.
    /// @param basketId корзина
    /// @param stable стейбл
    /// @param amount сумма стейбла
    /// @return tokensOut токенов корзины
    function previewMint(uint256 basketId, address stable, uint256 amount) external view returns (uint256 tokensOut) {
        Basket storage b = _basket(basketId);
        Stable storage s = _activeStable(stable);
        (,, tokensOut) = _quoteMint(b, s, _price(s), amount);
    }

    /// @notice Сколько пользователь получит при выкупе сейчас (с учётом уровня). 0, если выкуп приостановлен.
    /// @param basketId корзина
    /// @param stable стейбл выплаты
    /// @param tokenAmount токенов к выкупу
    /// @return stableOut выплата после комиссии
    /// @return fee комиссия
    function previewRedeem(uint256 basketId, address stable, uint256 tokenAmount)
        external
        view
        returns (uint256 stableOut, uint256 fee)
    {
        RedeemQuote memory q = quoteRedeem(basketId, stable, tokenAmount);
        return (q.payoutNow, q.feeNow);
    }

    /// @notice Полная котировка выкупа для сайта: уровень, покрытие, сумма сейчас и сумма с буфером.
    /// @dev executableNow не проверяет баланс конкретного пользователя (только totalSupply).
    /// @param basketId корзина
    /// @param stable стейбл выплаты
    /// @param tokenAmount токенов к выкупу
    /// @return q котировка
    function quoteRedeem(uint256 basketId, address stable, uint256 tokenAmount)
        public
        view
        returns (RedeemQuote memory q)
    {
        Basket storage b = _basket(basketId);
        Stable storage s = _activeStable(stable);
        uint256 p = _price(s);
        q.coverageBps = _coverageBps(basketId);
        q.tier = _tierOf(q.coverageBps);
        q.reserveAvailable = reserves[basketId][stable];

        (uint256 grossFull, uint256 feeFull) = _quoteRedeem(b, s, p, tokenAmount, true);
        q.payoutWithBuffer = grossFull - feeFull;

        uint256 gross = 0;
        if (q.tier != RedeemTier.Suspended) {
            (gross, q.feeNow) = _quoteRedeem(b, s, p, tokenAmount, q.tier == RedeemTier.Full);
            q.payoutNow = gross - q.feeNow;
        }
        q.executableNow = q.tier != RedeemTier.Suspended && !paused() && !_isDepegged(p) && gross <= q.reserveAvailable
            && q.payoutNow > 0 && tokenAmount <= b.token.totalSupply();
    }

    /// @notice Покрытие корзины в bps (12000 = 120%). При totalSupply = 0 возвращает type(uint256).max.
    /// @param basketId корзина
    /// @return покрытие, bps (округление вниз)
    function collateralRatioBps(uint256 basketId) external view returns (uint256) {
        _basket(basketId);
        return _coverageBps(basketId);
    }

    /// @notice Текущий уровень выкупа корзины (вычисляется на лету, может отличаться от lastTier,
    ///         если цена фида изменилась без транзакции — тогда вызовите pokeTier).
    /// @param basketId корзина
    /// @return уровень
    function redeemTier(uint256 basketId) external view returns (RedeemTier) {
        _basket(basketId);
        return _tierOf(_coverageBps(basketId));
    }

    /// @notice Допустимый диапазон следующего индекса корзины (для сайта/бота и проверок до транзакции).
    /// @param basketId корзина
    /// @return minAllowed нижняя граница включительно, ceil(index × 0,89)
    /// @return maxAllowed верхняя граница включительно, floor(index × 1,11)
    function indexBounds(uint256 basketId) external view returns (uint256 minAllowed, uint256 maxAllowed) {
        return _indexBounds(_basket(basketId).index);
    }

    /// @notice Число включённых стейблов.
    /// @return количество
    function stableCount() external view returns (uint256) {
        return stableList.length;
    }

    /// @notice Число корзин.
    /// @return количество
    function basketCount() external view returns (uint256) {
        return basketIds.length;
    }

    // ---------------------------------------------------------------------
    // Внутренние
    // ---------------------------------------------------------------------
    /// @dev Границы округляются в сторону строгости: нижняя вверх, верхняя вниз — диапазон никогда не шире ±11%.
    ///      old <= MAX_PRICE = 1e36, поэтому old × 11100 не переполняется; mulDiv — для единообразия.
    function _indexBounds(uint256 oldIndex) internal pure returns (uint256 minAllowed, uint256 maxAllowed) {
        minAllowed = Math.mulDiv(oldIndex, BPS - MAX_INDEX_CHANGE_BPS, BPS, Math.Rounding.Ceil);
        maxAllowed = Math.mulDiv(oldIndex, BPS + MAX_INDEX_CHANGE_BPS, BPS);
    }

    function _validateFeeRecipient(address r) internal view {
        if (r == address(0)) revert ZeroAddress();
        if (r == address(this)) revert InvalidFeeRecipient(r);
    }

    function _addStable(address stable, IAggregatorV3 feed, uint256 maxFeedStaleness, bool viaTimelock) internal {
        if (stable == address(0)) revert ZeroAddress();
        if (stables[stable].enabled) revert StableAlreadyEnabled(stable);
        uint8 dec = IERC20Metadata(stable).decimals();
        if (dec > 18) revert UnsupportedDecimals(dec);
        stables[stable] = Stable({
            enabled: true, decimals: dec, feed: feed, manualPrice: ONE_USD, maxFeedStaleness: maxFeedStaleness
        });
        stableList.push(stable);
        emit StableAdded(stable, dec, address(feed), maxFeedStaleness, viaTimelock);
    }

    function _basket(uint256 basketId) internal view returns (Basket storage b) {
        b = baskets[basketId];
        if (!b.exists) revert UnknownBasket(basketId);
    }

    function _activeStable(address stable) internal view returns (Stable storage s) {
        s = stables[stable];
        if (!s.enabled) revert StableNotEnabled(stable);
    }

    /// @dev Цена для mint/redeem. Если у стейбла есть фид, он обязан быть валиден (иначе FeedUnavailable):
    ///      откат на ручную цену здесь запрещён, чтобы сломанный/устаревший фид не скрыл депег (T1/T5).
    function _checkedPrice(address stable, Stable storage s) internal view returns (uint256 p) {
        if (address(s.feed) != address(0)) {
            bool ok;
            (ok, p) = _readFeed(address(s.feed), s.maxFeedStaleness);
            if (!ok) revert FeedUnavailable(stable);
        } else {
            p = s.manualPrice;
        }
        if (_isDepegged(p)) revert StableDepegged(stable, p);
    }

    /// @dev Chainlink L2 Sequencer Uptime: answer 0 — работает, 1 — упал; после восстановления ждём
    ///      SEQUENCER_GRACE_PERIOD. Невалидный ответ фида — отказ (безопасная сторона).
    function _checkSequencer() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;
        (bool ok, uint256 len, uint256[5] memory r) = _staticcallWords5(feed, IAggregatorV3.latestRoundData.selector);
        if (!ok || len < 160) revert SequencerFeedInvalid();
        // r = [roundId, answer, startedAt, updatedAt, answeredInRound]
        if (r[1] == 1) revert SequencerDown();
        // forge-lint: disable-next-line(block-timestamp)
        if (r[1] != 0 || r[2] == 0 || r[2] > block.timestamp) revert SequencerFeedInvalid();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - r[2] <= SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod(r[2]);
    }

    /// @dev Цена 18 знаков: фид, если ответ валиден, иначе ручная цена.
    function _price(Stable storage s) internal view returns (uint256) {
        if (address(s.feed) != address(0)) {
            (bool ok, uint256 p) = _readFeed(address(s.feed), s.maxFeedStaleness);
            if (ok) return p;
        }
        return s.manualPrice;
    }

    /// @dev Чтение фида без возможности DoS: staticcall с лимитом газа, фиксированным буфером ответа
    ///      (нет «return bomb» — копируется не более 160/32 байт) и проверкой длины ответа
    ///      (try/catch не ловит ошибку декодирования ответа и переполнение после вызова).
    ///      Ответ невалиден, если: вызов упал; ответ короче ожидаемого; answer <= 0 или > MAX_FEED_ANSWER;
    ///      updatedAt == 0, в будущем или старше maxStaleness; answeredInRound < roundId (неполный раунд);
    ///      decimals() упал, ответ короче 32 байт или decimals > 18.
    function _readFeed(address feed, uint256 maxStaleness) internal view returns (bool ok, uint256 price) {
        (bool s1, uint256 len1, uint256[5] memory r) = _staticcallWords5(feed, IAggregatorV3.latestRoundData.selector);
        if (!s1 || len1 < 160) return (false, 0);
        // r = [roundId, answer, startedAt, updatedAt, answeredInRound]
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = int256(r[1]); // побитовая интерпретация ABI-слова int256
        if (answer <= 0) return (false, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer); // answer > 0 проверен выше
        if (a > MAX_FEED_ANSWER) return (false, 0);
        uint256 updatedAt = r[3];
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            return (false, 0);
        }
        if (r[4] < r[0]) return (false, 0); // answeredInRound < roundId
        (bool s2, uint256 len2, uint256 fd) = _staticcallWord(feed, IAggregatorV3.decimals.selector);
        if (!s2 || len2 < 32 || fd > 18) return (false, 0);
        return (true, a * 10 ** (18 - fd));
    }

    /// @dev staticcall без аргументов, копирует не более 5 слов ответа.
    function _staticcallWords5(address target, bytes4 selector)
        private
        view
        returns (bool success, uint256 returnSize, uint256[5] memory out)
    {
        uint256 gasLimit = FEED_GAS_LIMIT;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(gasLimit, target, 0x00, 4, out, 160)
            returnSize := returndatasize()
        }
    }

    /// @dev staticcall без аргументов, копирует не более 1 слова ответа.
    function _staticcallWord(address target, bytes4 selector)
        private
        view
        returns (bool success, uint256 returnSize, uint256 word)
    {
        uint256 gasLimit = FEED_GAS_LIMIT;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(gasLimit, target, 0x00, 4, 0x00, 32)
            returnSize := returndatasize()
            word := mload(0x00)
        }
    }

    function _isDepegged(uint256 p) internal pure returns (bool) {
        uint256 band = (ONE_USD * DEPEG_BPS) / BPS; // 0.05e18
        return p < ONE_USD - band || p > ONE_USD + band;
    }

    /// @dev floor(amount * 10^(18-dec) * price / 1e18) без переполнения промежуточного произведения.
    function _toUsd(uint256 amount, uint8 dec, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(amount * 10 ** (18 - dec), price, 1e18);
    }

    function _pull(address stable, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = IERC20(stable).balanceOf(address(this));
        IERC20(stable).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(stable).balanceOf(address(this)) - balBefore;
    }

    /// @dev МИНТ: fee = ceil(amount*0,3%); tokens = floor((amount-fee) * scale * min(p,$1) / (P*1,2))
    ///      одной операцией mulDiv (одно округление, вниз). Мин. минт — по floor(amount*min(p,$1))
    ///      до комиссии протокола.
    function _quoteMint(Basket storage b, Stable storage s, uint256 sPrice, uint256 amount)
        internal
        view
        returns (uint256 fee, uint256 net, uint256 tokensOut)
    {
        uint256 valuationPrice = sPrice < ONE_USD ? sPrice : ONE_USD; // min(price, $1)
        uint256 grossUsd = _toUsd(amount, s.decimals, valuationPrice);
        if (grossUsd < minMintUsd) revert BelowMinMint(grossUsd, minMintUsd);
        fee = Math.mulDiv(amount, FEE_BPS, BPS, Math.Rounding.Ceil);
        net = amount - fee;
        tokensOut =
            Math.mulDiv(net * 10 ** (18 - s.decimals), valuationPrice * BPS, b.workingPrice * (BPS + BUFFER_BPS));
    }

    /// @dev Все проверки выкупа: стейбл активен, не депег, выкуп не приостановлен, хватает резерва.
    function _checkedRedeem(uint256 basketId, address stable, uint256 tokenAmount)
        internal
        view
        returns (uint256 gross, OpLog memory lg)
    {
        Stable storage s = _activeStable(stable);
        lg.stablePrice = _checkedPrice(stable, s);
        lg.coverageBefore = _coverageBps(basketId);
        lg.tier = _tierOf(lg.coverageBefore);
        if (lg.tier == RedeemTier.Suspended) {
            revert RedemptionSuspended(basketId, lg.coverageBefore, MIN_REDEEM_COVERAGE_BPS);
        }
        (gross, lg.fee) = _quoteRedeem(baskets[basketId], s, lg.stablePrice, tokenAmount, lg.tier == RedeemTier.Full);
        uint256 available = reserves[basketId][stable];
        if (gross > available) revert InsufficientReserve(gross, available);
    }

    /// @dev coverage = floor(Σ reserve_i * min(p_i, $1) * BPS / (totalSupply * P)).
    function _coverageBps(uint256 basketId) internal view returns (uint256) {
        Basket storage b = baskets[basketId];
        // forge-lint: disable-next-line(calls-loop) — view-вызов доверенного токена; цикл по корзинам ограничен owner
        uint256 supply = b.token.totalSupply();
        if (supply == 0) return type(uint256).max;
        uint256 usd = _reserveUsd(basketId);
        // usd / P даёт «сколько токенов покрыто» (18 знаков, потеря <= 1 wei), затем * BPS / supply.
        // Без переполнения промежуточных произведений (mulDiv 512-бит).
        return Math.mulDiv(Math.mulDiv(usd, 1e18, b.workingPrice), BPS, supply);
    }

    /// @dev Σ reserve_i * min(p_i, $1), USD 18 знаков (вынесено из _coverageBps в v5 без изменения формулы).
    function _reserveUsd(uint256 basketId) internal view returns (uint256 usd) {
        uint256 n = stableList.length;
        for (uint256 i; i < n; ++i) {
            address st = stableList[i];
            uint256 r = reserves[basketId][st];
            if (r == 0) continue;
            Stable storage s = stables[st];
            uint256 p = _coveragePrice(s);
            if (p == 0) continue;
            usd += _toUsd(r, s.decimals, p < ONE_USD ? p : ONE_USD);
        }
    }

    /// @dev v5.1 (M3): цена для оценки покрытия. Стейбл без фида — ручная цена. Стейбл с фидом, когда фид
    ///      невалиден (сломан/устарел/неполный раунд), — худший случай: 0 (резерв не засчитывается), чтобы
    ///      выкуп по 1,2P (FULL) и минт не проходили по завышенному покрытию.
    function _coveragePrice(Stable storage s) internal view returns (uint256) {
        if (address(s.feed) == address(0)) return s.manualPrice;
        (bool ok, uint256 p) = _readFeed(address(s.feed), s.maxFeedStaleness);
        return ok ? p : 0;
    }

    function _tierOf(uint256 coverageBps) internal pure returns (RedeemTier) {
        if (coverageBps >= FULL_REDEEM_COVERAGE_BPS) return RedeemTier.Full;
        if (coverageBps >= MIN_REDEEM_COVERAGE_BPS) return RedeemTier.Standard;
        return RedeemTier.Suspended;
    }

    function _syncTier(uint256 basketId) internal {
        _syncTierAt(basketId, _coverageBps(basketId));
    }

    /// @dev Как _syncTier, но с уже посчитанным покрытием (экономия газа в mint/redeem/topUp).
    function _syncTierAt(uint256 basketId, uint256 cov) internal {
        RedeemTier newTier = _tierOf(cov);
        RedeemTier old = lastTier[basketId];
        if (newTier != old) {
            lastTier[basketId] = newTier;
            // forge-lint: disable-next-line(reentrancy-events) — вызывается только из nonReentrant/owner-функций
            emit CoverageTierChanged(basketId, old, newTier, cov);
        }
    }

    function _syncAllTiers() internal {
        uint256 n = basketIds.length;
        for (uint256 i; i < n; ++i) {
            _syncTier(basketIds[i]);
        }
    }

    /// @dev Фиксирует переход стейбла в депег / из депега и выпускает событие только при смене статуса.
    function _syncDepeg(address stable, uint256 price) internal {
        bool now_ = _isDepegged(price);
        if (now_ != lastDepegged[stable]) {
            lastDepegged[stable] = now_;
            // forge-lint: disable-next-line(reentrancy-events) — вызывается только из nonReentrant/owner-функций
            emit StableDepegStatusChanged(stable, now_, price);
        }
    }

    function _syncAllDepeg() internal {
        uint256 n = stableList.length;
        for (uint256 i; i < n; ++i) {
            address st = stableList[i];
            _syncDepeg(st, _price(stables[st]));
        }
    }

    /// @dev Вынесено в отдельную функцию: 11 полей события + локальные переменные mint не помещаются в стек
    ///      (stack too deep без via_ir). Данные передаются одной memory-структурой.
    function _emitMinted(uint256 basketId, address stable, uint256 workingPrice, OpLog memory lg) private {
        // forge-lint: disable-start(reentrancy-events) — вызывается только из nonReentrant функции
        emit Minted(
            basketId,
            msg.sender,
            stable,
            lg.stableAmount,
            lg.fee,
            lg.tokens,
            workingPrice,
            lg.stablePrice,
            lg.tier,
            lg.coverageBefore,
            lg.coverageAfter
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @dev См. _emitMinted.
    function _emitRedeemed(uint256 basketId, address stable, uint256 workingPrice, OpLog memory lg) private {
        // forge-lint: disable-start(reentrancy-events) — вызывается только из nonReentrant функции
        emit Redeemed(
            basketId,
            msg.sender,
            stable,
            lg.tokens,
            lg.stableAmount,
            lg.fee,
            workingPrice,
            lg.stablePrice,
            lg.tier,
            lg.coverageBefore,
            lg.coverageAfter
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @dev gross = floor(tokens * P * k / (BPS * max(p,$1) * 10^(18-dec))), k = 12000 (FULL) или 10000;
    ///      одно округление (вниз). fee = ceil(gross * 0,3%).
    function _quoteRedeem(Basket storage b, Stable storage s, uint256 sPrice, uint256 tokenAmount, bool withBuffer)
        internal
        view
        returns (uint256 gross, uint256 fee)
    {
        uint256 k = withBuffer ? BPS + BUFFER_BPS : BPS;
        uint256 payPrice = sPrice > ONE_USD ? sPrice : ONE_USD; // max(price, $1)
        gross = Math.mulDiv(tokenAmount, b.workingPrice * k, BPS * payPrice * 10 ** (18 - s.decimals));
        fee = Math.mulDiv(gross, FEE_BPS, BPS, Math.Rounding.Ceil);
    }
}
