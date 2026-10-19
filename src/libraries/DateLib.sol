// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DateLib
/// @notice Перевод unix-времени (UTC) в календарную дату без внешних зависимостей.
/// @dev Алгоритм civil_from_days (Howard Hinnant), тот же подход, что в BokkyPooBahsDateTimeLibrary.
library DateLib {
    uint256 internal constant SECONDS_PER_DAY = 86400;

    // Целочисленная календарная арифметика: деление до умножения и знаковые приведения здесь намеренные
    // (диапазоны значений указаны в комментариях; timestamp < 2^255, поэтому int256 не переполняется).
    // forge-lint: disable-start(divide-before-multiply, unsafe-typecast)
    // slither-disable-start divide-before-multiply
    function timestampToDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 z = int256(timestamp / SECONDS_PER_DAY) + 719468;
        int256 era = z / 146097; // timestamp >= 0, поэтому z > 0
        int256 doe = z - era * 146097; // [0, 146096]
        int256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
        int256 y = yoe + era * 400;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
        int256 mp = (5 * doy + 2) / 153; // [0, 11]
        int256 d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
        int256 m = mp < 10 ? mp + 3 : mp - 9; // [1, 12]
        if (m <= 2) y += 1;
        year = uint256(y);
        month = uint256(m);
        day = uint256(d);
    }
    // slither-disable-end divide-before-multiply
    // forge-lint: disable-end(divide-before-multiply, unsafe-typecast)
}
