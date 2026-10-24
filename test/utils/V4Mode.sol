// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// v5: режим регрессии v4 для тестов. Обнуляет пол и сужение и ставит максимальные лимиты окна/блока
/// прямой записью в слот `mintLimits` (через публичный API так сделать нельзя — границы).
library V4Mode {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// Слот `mintLimits` (forge inspect BasketVault storageLayout). Проверяется в MintLimits.t.sol.
    uint256 internal constant MINT_LIMITS_SLOT = 17;

    function disableMintLimits(address vault) internal {
        // упаковка: floor | taper << 32 | hourCap << 64 | blockCap << 96 (uint32 каждый); лимиты ~429 000x резерва
        uint256 packed = (uint256(type(uint32).max) << 64) | (uint256(type(uint32).max) << 96);
        VM.store(vault, bytes32(MINT_LIMITS_SLOT), bytes32(packed));
    }
}
