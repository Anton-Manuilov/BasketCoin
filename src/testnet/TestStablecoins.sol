// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestStablecoin
/// @notice ТОЛЬКО ДЛЯ ТЕСТНЕТА. ERC20 с 6 знаками и открытым краном: любой адрес может
///         выпустить себе до FAUCET_LIMIT за один вызов. Ценности не имеет.
/// @dev Цены у этих токенов нет — BasketVault использует ручную цену $1 (фид = address(0)).
abstract contract TestStablecoin is ERC20 {
    /// @notice Максимум за один вызов faucet: 10 000 токенов (6 знаков).
    uint256 public constant FAUCET_LIMIT = 10_000e6;

    /// @notice Сумма запроса больше лимита или равна нулю.
    error FaucetAmountInvalid(uint256 amount, uint256 limit);

    /// @notice Кто-то получил тестовые токены из крана.
    event FaucetMinted(address indexed to, uint256 amount);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice 6 знаков, как у настоящих USDT/USDC.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Кран: выпускает `amount` (6 знаков, 1 токен = 1_000_000) вызывающему.
    /// @param amount 0 < amount <= FAUCET_LIMIT
    function faucet(uint256 amount) external {
        if (amount == 0 || amount > FAUCET_LIMIT) revert FaucetAmountInvalid(amount, FAUCET_LIMIT);
        _mint(msg.sender, amount);
        emit FaucetMinted(msg.sender, amount);
    }
}

/// @title TestUSDT
/// @notice Тестовый USDT для Base Sepolia (6 знаков, открытый кран).
contract TestUSDT is TestStablecoin {
    constructor() TestStablecoin("Test Tether USD (BasketCoin testnet)", "tUSDT") {}
}

/// @title TestUSDC
/// @notice Тестовый USDC для Base Sepolia (6 знаков, открытый кран).
contract TestUSDC is TestStablecoin {
    constructor() TestStablecoin("Test USD Coin (BasketCoin testnet)", "tUSDC") {}
}
