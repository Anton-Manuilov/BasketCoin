// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BasketToken
/// @notice ERC20-токен корзины (сейчас — один «средний» BasketCoin).
/// @dev Токен не хранит залог и не знает об индексе: минт и сжигание делает только
///      адрес с ролью MINTER_ROLE (BasketVault). Так в будущем можно выпустить
///      отдельные токены по валютам (например, BasketCoin-EUR) и подключить их к тому же Vault.
contract BasketToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Создаёт токен корзины и выдаёт `admin` роль DEFAULT_ADMIN_ROLE (он выдаёт MINTER_ROLE Vault).
    /// @param name_ имя токена
    /// @param symbol_ тикер токена
    /// @param admin администратор ролей (рекомендуется multisig)
    constructor(string memory name_, string memory symbol_, address admin) ERC20(name_, symbol_) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Выпуск токенов. Только MINTER_ROLE (Vault). Эмиссия не ограничена.
    /// @param to получатель
    /// @param amount количество (18 знаков)
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Сжигание токенов у `from`. Только MINTER_ROLE (Vault сжигает токены того, кто вызывает redeem).
    /// @dev Allowance не требуется: доверие к MINTER_ROLE полное (см. AUDIT_REPORT, риски централизации).
    /// @param from чей баланс уменьшается
    /// @param amount количество (18 знаков)
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }
}
