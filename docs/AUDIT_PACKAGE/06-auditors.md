# 6. Аудиторы: варианты, ориентировочные цены и сроки

Scope: ≈691 nSLOC (раздел README), один vault + ERC20 + библиотека дат, одна внешняя интеграция (Chainlink-совместимый фид, опционально).
Данные — из открытых источников на 20.10.2026; это **не** коммерческие предложения. Цену назначают после скоупинга.

| Фирма / платформа | Формат | Цена (по источнику) | Сроки (по источнику) | Источник |
|---|---|---|---|---|
| **Hacken** | частный аудит, два аудитора + проверка исправлений (2 недели) | публикует диапазон: обычно **$3 000 – $100 000+** | простые контракты **5–10 рабочих дней**, большинство 2–4 недели; полный цикл 5–15 рабочих дней | [hacken.io — Smart Contract Audit](https://hacken.io/services/blockchain-security/smart-contract-security-audit/), [Solidity audit](https://hacken.io/services/blockchain-security/solidity-smart-contract-security-audit/) |
| **Pashov Audit Group** | частный аудит, 4 старших аудитора на проект, fix review | **не публикует**, индивидуальная оценка (audits@pashov.com, Telegram @pashovkrum) | один контракт **3–5 дней**, сложный DeFi 2–4 недели; заявляют «старт сразу» | [pashov.com](https://www.pashov.com/), [request-audit](https://www.pashov.com/request-audit) |
| **Cyfrin** (частный аудит; CodeHawks — конкурсы) | частный аудит с mitigation-раундом | **не публикует**, оценка после созвона | по объёму кода, в оценке | [Guardix: сравнение фирм](https://guardix.io/smart-contract-audit-firms/), [CodeHawks FAQ (методика nSLOC)](https://docs.codehawks.com/faqs) |
| **Sherlock** | конкурс или «collaborative audit» | **не публикует** цену; по обзору DeFiSec медиана призового фонда 20 последних публичных конкурсов ≈ $152 600 (диапазон $104 000 – $1,39 млн) | ориентир Sherlock: **~500 nSLOC ≈ 3 дня**, ~1000 ≈ 6 дней | [docs.sherlock.xyz — timeline](https://docs.sherlock.xyz/audits/protocols/audit-pricing-and-timeline.md), [DeFiSec обзор конкурсов](https://defisec.info/blog/smart-contract-audit-contest) |
| **Code4rena** | конкурс | пулы последних 20 конкурсов **$4 000 – $183 500**, медиана $38 750 (пример: Intuition, март 2026 — $17 500) | медиана 9,5 дня | [DeFiSec](https://defisec.info/blog/smart-contract-audit-contest), [пример README конкурса](https://github.com/code-423n4/2026-03-intuition/blob/main/README.md). **Важно:** по DeFiSec, на 04.09.2026 главная Code4rena сообщает о закрытии («winding down») — новые конкурсы, вероятно, недоступны |

## Ориентиры рынка (не цены конкретных фирм)
- Sherlock, «Smart Contract Audit Pricing: A Market Reference for 2026»: простой ERC-20 — $5 000–$20 000; DeFi средней сложности — $40 000–$100 000;
  повторная проверка после исправлений — $5 000–$20 000 за проход.
  [sherlock.xyz](https://sherlock.xyz/post/smart-contract-audit-pricing-a-market-reference-for-2026)
- Zealynx: <500 nSLOC — $5K–$15K, 2–5 дней; 1000–3000 nSLOC — $40K–$100K, 2–4 недели.
  [zealynx.io](https://www.zealynx.io/research/audit-ops/audit-scoping-guide)
- Procur3: staking/vault 1000–3000 nSLOC — $5K–$60K, 3–4 недели; срочность +20–40%.
  [procur3.io](https://procur3.io/blog/smart-contract-audit-cost-2026)

## Вывод для BasketCoin
При ≈700 nSLOC и логике vault (покрытие, уровни, цены стейблов) проект между «простым токеном» и «DeFi средней сложности».
Реалистичный бюджет по открытым ориентирам — **порядка $10 000–$40 000 плюс $5 000–$20 000 на повторную проверку**; срок — 1–2 недели работы
плюс ожидание слота. Это оценка по рыночным обзорам, а не котировка: запросить предложения у 2–3 фирм с этим пакетом и коммитом `bdfada3`
(или новым, если будет этап B из раздела 5).
