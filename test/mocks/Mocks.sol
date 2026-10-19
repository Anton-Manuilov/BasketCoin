// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// Стандартный ERC20 с настраиваемыми decimals.
contract MockStable is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Токен с комиссией за перевод (fee-on-transfer), feeBps удерживается и сжигается.
contract FeeOnTransferStable is MockStable {
    uint256 public feeBps;

    constructor(uint256 feeBps_) MockStable("FoT", "FOT", 6) {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// USDT-подобный токен: transfer/transferFrom/approve НЕ возвращают bool.
contract NoReturnStable {
    string public name = "Tether-like";
    string public symbol = "USDTL";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        require(balanceOf[f] >= a, "bal");
        if (allowance[f][msg.sender] != type(uint256).max) {
            require(allowance[f][msg.sender] >= a, "allow");
            allowance[f][msg.sender] -= a;
        }
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// Токен, который при включённом флаге возвращает false вместо revert.
contract ReturnFalseStable is MockStable {
    bool public failTransfers;

    constructor() MockStable("False", "FALSE", 6) {}

    function setFail(bool f) external {
        failTransfers = f;
    }

    function transfer(address to, uint256 a) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, a);
    }

    function transferFrom(address f, address to, uint256 a) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(f, to, a);
    }
}

interface IHookReceiver {
    function onTokenHook(address from, address to, uint256 amount) external;
}

/// ERC777-подобный токен: при каждом переводе вызывает хук у отправителя и получателя (если задан).
contract HookStable is MockStable {
    mapping(address => bool) public hooked;

    constructor() MockStable("Hook", "HOOK", 6) {}

    function setHooked(address a, bool h) external {
        hooked[a] = h;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && hooked[from]) IHookReceiver(from).onTokenHook(from, to, value);
        super._update(from, to, value);
        if (to != address(0) && hooked[to]) IHookReceiver(to).onTokenHook(from, to, value);
    }
}

/// Настраиваемый Chainlink-совместимый фид.
contract MockFeed is IAggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public dec;
    bool public broken;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 a) {
        dec = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setRounds(uint80 r, uint80 air) external {
        roundId = r;
        answeredInRound = air;
    }

    function setDecimals(uint8 d) external {
        dec = d;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function decimals() external view returns (uint8) {
        require(!broken, "feed down");
        return dec;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// Фид, отвечающий слишком коротким ответом (не по ABI).
contract ShortReturnFeed {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// Фид с огромным ответом (return bomb).
contract ReturnBombFeed {
    fallback() external {
        assembly {
            return(0, 1000000)
        }
    }
}

/// Фид, сжигающий весь газ.
contract GasGuzzlerFeed {
    fallback() external {
        while (true) {}
    }
}
