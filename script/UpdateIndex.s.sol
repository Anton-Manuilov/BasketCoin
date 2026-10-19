// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BasketVault} from "../src/BasketVault.sol";
import {DateLib} from "../src/libraries/DateLib.sol";

/// @title UpdateIndex
/// @notice Ежемесячное обновление индекса корзины владельцем (28-го числа по UTC).
///         Сначала проверяет всё то же, что проверит контракт (день, месяц, лимит ±11%), и только потом
///         отправляет setIndex. Подпись — флагами forge: --ledger, --trezor, --interactive, --account <keystore>.
///
/// Переменные окружения:
///   VAULT      — адрес BasketVault (обязательно)
///   NEW_INDEX  — новый индекс, USD 18 знаков (обязательно; 1.0234 = 1023400000000000000)
///   BASKET_ID  — корзина (по умолчанию 1)
///
/// Проверка без отправки:  forge script script/UpdateIndex.s.sol --rpc-url $RPC
/// Отправка:               forge script script/UpdateIndex.s.sol --rpc-url $RPC --broadcast --ledger --sender $OWNER
contract UpdateIndex is Script {
    function run() external {
        BasketVault vault = BasketVault(vm.envAddress("VAULT"));
        uint256 newIndex = vm.envUint("NEW_INDEX");
        uint256 basketId = vm.envOr("BASKET_ID", uint256(1));

        (, uint256 oldIndex, uint256 working, uint256 lastKey,,) = vault.baskets(basketId);
        (uint256 minAllowed, uint256 maxAllowed) = vault.indexBounds(basketId);
        (uint256 y, uint256 m, uint256 d) = DateLib.timestampToDate(block.timestamp);

        console2.log("owner        ", vault.owner());
        console2.log("UTC date (y/m/d)", y, m, d);
        console2.log("current index", oldIndex);
        console2.log("working price", working);
        console2.log("allowed min  ", minAllowed);
        console2.log("allowed max  ", maxAllowed);
        console2.log("new index    ", newIndex);

        require(d == vault.INDEX_UPDATE_DAY(), "not the 28th (UTC) in the latest block");
        require(lastKey != y * 12 + (m - 1), "index already updated this month");
        require(newIndex >= minAllowed && newIndex <= maxAllowed, "new index outside +-11% bounds");

        vm.startBroadcast(); // подписант задаётся флагами командной строки (--ledger / --interactive / --account)
        vault.setIndex(basketId, newIndex);
        vm.stopBroadcast();

        (, uint256 idx,,,,) = vault.baskets(basketId);
        console2.log("index after  ", idx);
    }
}
