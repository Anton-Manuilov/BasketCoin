// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {BasketToken} from "../src/BasketToken.sol";
import {TestUSDT, TestUSDC} from "../src/testnet/TestStablecoins.sol";

/// @title Deploy
/// @notice Деплой тестнет-набора BasketCoin: TestUSDT, TestUSDC, BasketToken, BasketVault, корзина 1.
///
/// Переменные окружения:
///   DEPLOYER_PK       — приватный ключ деплоера (обязательно; хранится вне репозитория)
///   OWNER_ADDRESS     — будущий владелец Vault: Safe 2-of-3 в mainnet (по умолчанию — деплоер)
///   GUARDIAN_ADDRESS  — guardian паузы, отдельный адрес (может только поставить паузу; по умолчанию — нет)
///   SEQUENCER_UPTIME_FEED — Chainlink L2 Sequencer Uptime Feed (по умолчанию 0 = проверка выключена;
///                       в тестнете 0, в Base mainnet — только адрес из официальной документации Chainlink)
///   FEE_RECIPIENT     — казна для комиссий (по умолчанию — OWNER_ADDRESS, а если он не задан — деплоер)
///   MIN_MINT_USD      — минимальный минт, USD 18 знаков (по умолчанию 50e18 = $50)
///   INITIAL_INDEX     — стартовый индекс корзины, 18 знаков (по умолчанию 1e18 = $1,00)
///   BASKET_ID         — id корзины (по умолчанию 1)
///   USDT_FEED / USDC_FEED — Chainlink USDT/USD и USDC/USD (по умолчанию 0 = ручная цена $1); адреса — config/chainlink-feeds.md
///   FEED_STALENESS    — допустимый возраст ответа фидов, с (по умолчанию 90000 = 25 ч при heartbeat 24 ч)
///   USDT_ADDRESS / USDC_ADDRESS — переиспользовать существующие тестовые стейблы (по умолчанию — развернуть новые)
///   DEPLOYMENTS_FILE  — куда записать адреса (по умолчанию deployments/base-sepolia.json при chainId 84532,
///                       иначе deployments/<chainId>.json)
///
/// Передача прав, если OWNER_ADDRESS != деплоер:
///   - Vault (Ownable2Step): transferOwnership(OWNER) — владелец остаётся деплоером, пока OWNER не вызовет
///     acceptOwnership(). До этого OWNER числится pendingOwner.
///   - BasketToken (AccessControl): DEFAULT_ADMIN_ROLE передаётся самому Vault (всегда), деплоер отказывается
///     от своей роли. Дальше роли токена меняются только через таймлок Vault (setTokenRole, 7 дней).
contract Deploy is Script {
    struct Deployed {
        address usdt;
        address usdc;
        address token;
        address vault;
    }

    struct Config {
        uint256 deployerPk;
        address owner;
        address feeRecipient;
        address guardian;
        address sequencerUptimeFeed;
        uint256 minMintUsd;
        uint256 initialIndex;
        uint256 basketId;
        string deploymentsFile;
    }

    /// @notice Точка входа forge script: параметры из переменных окружения.
    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        string memory def = block.chainid == 84532
            ? "deployments/base-sepolia.json"
            : string.concat("deployments/", vm.toString(block.chainid), ".json");
        d = deploy(
            Config({
                deployerPk: pk,
                owner: owner,
                feeRecipient: vm.envOr("FEE_RECIPIENT", owner),
                guardian: vm.envOr("GUARDIAN_ADDRESS", address(0)),
                sequencerUptimeFeed: vm.envOr("SEQUENCER_UPTIME_FEED", address(0)),
                minMintUsd: vm.envOr("MIN_MINT_USD", uint256(50e18)),
                initialIndex: vm.envOr("INITIAL_INDEX", uint256(1e18)),
                basketId: vm.envOr("BASKET_ID", uint256(1)),
                deploymentsFile: vm.envOr("DEPLOYMENTS_FILE", def)
            })
        );
    }

    /// @notice Деплой с явными параметрами (используется run() и тестами).
    function deploy(Config memory c) public returns (Deployed memory d) {
        address deployer = vm.addr(c.deployerPk);
        address owner = c.owner;
        require(owner != address(0) && c.feeRecipient != address(0), "zero address");
        // v5.1 (L-1): в mainnet Base (8453) обязателен Chainlink L2 Sequencer Uptime Feed
        if (block.chainid == 8453) require(c.sequencerUptimeFeed != address(0), "sequencer feed required on Base");

        console2.log("chainId     ", block.chainid);
        console2.log("deployer    ", deployer);
        console2.log("owner       ", owner);
        console2.log("feeRecipient", c.feeRecipient);
        console2.log("guardian    ", c.guardian);
        console2.log("seqFeed     ", c.sequencerUptimeFeed);

        vm.startBroadcast(c.deployerPk);
        // v5.2: можно переиспользовать уже развёрнутые тестовые стейблы (USDT_ADDRESS / USDC_ADDRESS)
        d.usdt = vm.envOr("USDT_ADDRESS", address(0));
        d.usdc = vm.envOr("USDC_ADDRESS", address(0));
        if (d.usdt == address(0)) d.usdt = address(new TestUSDT());
        if (d.usdc == address(0)) d.usdc = address(new TestUSDC());
        // Vault и токен создаются с деплоером в роли владельца/админа, чтобы настроить их в той же сессии.
        BasketVault vault = new BasketVault(
            deployer,
            c.feeRecipient,
            d.usdt,
            d.usdc,
            c.minMintUsd,
            c.guardian,
            c.sequencerUptimeFeed,
            IAggregatorV3(vm.envOr("USDT_FEED", address(0))),
            IAggregatorV3(vm.envOr("USDC_FEED", address(0))),
            vm.envOr("FEED_STALENESS", uint256(90_000))
        );
        BasketToken token = new BasketToken("BasketCoin", "BKT", deployer);
        token.grantRole(token.MINTER_ROLE(), address(vault));
        vault.addBasket(c.basketId, token, c.initialIndex);

        token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(vault)); // роли токена — только через таймлок Vault
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), deployer);
        if (owner != deployer) {
            vault.transferOwnership(owner); // Ownable2Step: OWNER должен вызвать acceptOwnership()
        }
        vm.stopBroadcast();
        d.token = address(token);
        d.vault = address(vault);

        _check(d, deployer, owner, c);
        _write(d, deployer, c);
    }

    function _check(Deployed memory d, address deployer, address owner, Config memory c) internal view {
        uint256 basketId = c.basketId;
        uint256 initialIndex = c.initialIndex;
        BasketVault vault = BasketVault(d.vault);
        BasketToken token = BasketToken(d.token);
        require(token.hasRole(token.MINTER_ROLE(), d.vault), "vault not minter");
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), d.vault), "vault not token admin");
        require(!token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer), "deployer still admin");
        require(vault.guardian() == c.guardian, "guardian");
        require(vault.sequencerUptimeFeed() == c.sequencerUptimeFeed, "sequencer feed");
        require(vault.owner() == deployer, "vault owner");
        require(vault.pendingOwner() == (owner == deployer ? address(0) : owner), "pending owner");
        (, uint256 index, uint256 working,,,) = vault.baskets(basketId);
        require(index == initialIndex && working == initialIndex, "basket index");
        require(vault.stableCount() == 2, "stables");
    }

    function _write(Deployed memory d, address deployer, Config memory c) internal {
        address owner = c.owner;
        string memory path = c.deploymentsFile;
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeUint(k, "deployedAtTimestamp", block.timestamp);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "vaultOwner", deployer);
        vm.serializeAddress(k, "vaultPendingOwner", owner == deployer ? address(0) : owner);
        vm.serializeAddress(k, "tokenAdmin", d.vault);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "sequencerUptimeFeed", c.sequencerUptimeFeed);
        vm.serializeAddress(k, "usdtFeed", vm.envOr("USDT_FEED", address(0)));
        vm.serializeAddress(k, "usdcFeed", vm.envOr("USDC_FEED", address(0)));
        vm.serializeUint(k, "feedStaleness", vm.envOr("FEED_STALENESS", uint256(90_000)));
        vm.serializeAddress(k, "feeRecipient", c.feeRecipient);
        vm.serializeUint(k, "basketId", c.basketId);
        vm.serializeUint(k, "initialIndex", c.initialIndex);
        vm.serializeUint(k, "minMintUsd", c.minMintUsd);
        vm.serializeString(k, "tokenSymbol", BasketToken(d.token).symbol());
        vm.serializeAddress(k, "TestUSDT", d.usdt);
        vm.serializeAddress(k, "TestUSDC", d.usdc);
        vm.serializeAddress(k, "BasketToken", d.token);
        string memory json = vm.serializeAddress(k, "BasketVault", d.vault);
        vm.writeJson(json, path);
        console2.log("TestUSDT    ", d.usdt);
        console2.log("TestUSDC    ", d.usdc);
        console2.log("BasketToken ", d.token);
        console2.log("BasketVault ", d.vault);
        console2.log("written to  ", path);
    }
}
