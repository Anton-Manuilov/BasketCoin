# BasketCoin — пакет для внешнего аудита

Пакет собран 20.10.2026, обновлён 19.10.2026 под этап B (guardian, ограниченная пауза, таймлок, L2 sequencer). Это **не** отчёт аудита: внешнего аудита ещё не было,
есть только внутренняя проверка ([`AUDIT_REPORT.md`](../../AUDIT_REPORT.md)).

## Замороженный коммит (scope freeze)

| Поле | Значение |
|---|---|
| Репозиторий | https://github.com/Anton-Manuilov/BasketCoin (публичный) |
| Коммит для аудита | **`ab144a724e66d93b4a2014765886a18273f2d359`** («Stage B: guardian pause, admin timelock, L2 sequencer check», ветка `main`). Код `src/` для аудита — ровно этот коммит; последующие коммиты меняют только документы/деплой. Предыдущая заморозка `bdfada3` (до этапа B) устарела |
| Код `src/` (кроме `src/testnet/`) | изменён только `BasketVault.sol` (этап B); хеши файлов — [`appendix/scope.sha256`](appendix/scope.sha256) |
| Компилятор | solc 0.8.24, optimizer on, runs 200, без via-IR (`foundry.toml`) |
| Зависимости | OpenZeppelin Contracts 5.1.0, forge-std v1.17.0 (git-сабмодули) |
| Инструменты | Foundry (forge 1.8.5), Slither 0.11.6 |
| Целевая сеть | сейчас Base Sepolia (тестнет). Основная сеть не выбрана (вопрос к владельцу) |

### Scope

nSLOC здесь — строки без комментариев и пустых строк; у Solidity Metrics и CodeHawks методика немного другая,
значения могут отличаться на несколько процентов.

| Файл | Строк | nSLOC | В scope |
|---|---:|---:|---|
| `src/BasketVault.sol` | 1281 | 784 | да |
| `src/BasketToken.sol` | 38 | 16 | да |
| `src/libraries/DateLib.sol` | 31 | 19 | да |
| `src/interfaces/IAggregatorV3.sol` | 12 | 8 | да (интерфейс) |
| **Итого в scope** | **1362** | **≈827** (было ≈691) | |
| `src/testnet/TestStablecoins.sol` | 46 | 22 | нет: только для тестнета, в основную сеть не идёт |

Вне scope: `lib/` (OpenZeppelin, forge-std), `test/`, `script/`, сайт.

## Содержание
1. [Модель угроз](01-threat-model.md)
2. [Роли и параметры с пределами](02-roles-parameters.md)
3. [Методика индекса](03-index-methodology.md)
4. [Покрытие тестами и Slither](04-coverage-slither.md)
5. [План перехода на мультисиг (Safe) и таймлок](05-multisig-timelock-plan.md)
6. [Аудиторы: варианты, цены, сроки](06-auditors.md)

Приложения: [`appendix/coverage.txt`](appendix/coverage.txt), [`appendix/slither.txt`](appendix/slither.txt),
[`appendix/scope.sha256`](appendix/scope.sha256).

Другие документы репозитория: [`SPEC.md`](../../SPEC.md) (спецификация и формулы), [`AUDIT_REPORT.md`](../../AUDIT_REPORT.md)
(внутренняя проверка: инварианты, мутации, найденные и исправленные проблемы), [`docs/OPERATIONS.md`](../OPERATIONS.md) (эксплуатация).

## Как воспроизвести
```bash
git clone --recursive https://github.com/Anton-Manuilov/BasketCoin && cd BasketCoin
git checkout ab144a724e66d93b4a2014765886a18273f2d359
forge build && forge test                      # 230 тестов
FOUNDRY_PROFILE=ci forge test                  # fuzz 10 000, invariant 1000 × 200
forge coverage --report summary --no-match-coverage '(test|lib|script)/'
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```

## Тестнет (Base Sepolia, chainId 84532)
Vault `0xF6b93f9124d24AadEe6d38b9a925d220d731B4d6`, токен BKT `0x2E72B4D6E2d611E6a193287D0736DfAabddDB062`
(верифицированы на Blockscout и Sourcify; см. `deployments/base-sepolia.json`). Это набор v3 из кода **до этапа B**;
для проверки этапа B нужен новый тестнет-набор v4.
