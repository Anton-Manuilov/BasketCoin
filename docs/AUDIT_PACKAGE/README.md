# BasketCoin — пакет для внешнего аудита

Пакет собран 20.10.2026 для передачи аудиторам. Это **не** отчёт аудита: внешнего аудита ещё не было,
есть только внутренняя проверка ([`AUDIT_REPORT.md`](../../AUDIT_REPORT.md)).

## Замороженный коммит (scope freeze)

| Поле | Значение |
|---|---|
| Репозиторий | https://github.com/Anton-Manuilov/BasketCoin (публичный) |
| Коммит для аудита | **`bdfada3d87bac3464bbb599582f46057939d8cb5`** (ветка `main`, опубликован) |
| Код `src/` (кроме `src/testnet/`) | не менялся с `5e94199`; хеши файлов — [`appendix/scope.sha256`](appendix/scope.sha256) |
| Компилятор | solc 0.8.24, optimizer on, runs 200, без via-IR (`foundry.toml`) |
| Зависимости | OpenZeppelin Contracts 5.1.0, forge-std v1.17.0 (git-сабмодули) |
| Инструменты | Foundry (forge 1.8.5), Slither 0.11.6 |
| Целевая сеть | сейчас Base Sepolia (тестнет). Основная сеть не выбрана (вопрос к владельцу) |

### Scope

nSLOC здесь — строки без комментариев и пустых строк; у Solidity Metrics и CodeHawks методика немного другая,
значения могут отличаться на несколько процентов.

| Файл | Строк | nSLOC | В scope |
|---|---:|---:|---|
| `src/BasketVault.sol` | 1052 | 648 | да |
| `src/BasketToken.sol` | 38 | 16 | да |
| `src/libraries/DateLib.sol` | 31 | 19 | да |
| `src/interfaces/IAggregatorV3.sol` | 12 | 8 | да (интерфейс) |
| **Итого в scope** | **1133** | **≈691** | |
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
git checkout bdfada3d87bac3464bbb599582f46057939d8cb5
forge build && forge test                      # 204 теста
FOUNDRY_PROFILE=ci forge test                  # fuzz 10 000, invariant 1000 × 200
forge coverage --report summary --no-match-coverage '(test|lib|script)/'
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```

## Тестнет (Base Sepolia, chainId 84532)
Vault `0xF6b93f9124d24AadEe6d38b9a925d220d731B4d6`, токен BKT `0x2E72B4D6E2d611E6a193287D0736DfAabddDB062`
(верифицированы на Blockscout и Sourcify; см. `deployments/base-sepolia.json`). Тестнет-набор собран из того же кода `src/`.
