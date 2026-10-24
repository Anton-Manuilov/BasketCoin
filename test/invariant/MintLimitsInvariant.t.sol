// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";
import {MockStable} from "../mocks/Mocks.sol";

/// v5: handler с включённым ограничителем минта. Считает нарушения в ghost-переменных.
contract MintLimitHandler is Test {
    BasketVault public vault;
    BasketToken public coin;
    MockStable public usdt;
    address public owner;
    address[3] public actors;

    uint256 public vBelowFloor; // успешный минт оставил покрытие < пола
    uint256 public vWindowOverCap; // за окно заминчено больше hourCap от максимального резерва в окне
    uint256 public vBlockOverCap;
    uint256 public vUnexpectedMintRevert;
    uint256 public mintsOk;
    uint256 public mintsLimited;

    uint256 internal curWindow;
    uint256 internal windowUsed;
    uint256 internal windowMaxReserve;
    uint256 internal curBlock;
    uint256 internal blockUsed;
    uint256 internal blockMaxReserve;

    constructor(BasketVault v, BasketToken c, MockStable s, address o, address[3] memory a) {
        vault = v;
        coin = c;
        usdt = s;
        owner = o;
        actors = a;
    }

    function _reserve() internal view returns (uint256) {
        return vault.reserves(1, address(usdt)) * 1e12;
    }

    function mint(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        amt = bound(amt, 50e6, 300_000e6);
        uint256 r = _reserve();
        uint256 w = block.timestamp / 3600;
        if (w != curWindow) (curWindow, windowUsed, windowMaxReserve) = (w, 0, 0);
        if (block.number != curBlock) (curBlock, blockUsed, blockMaxReserve) = (block.number, 0, 0);
        if (r > windowMaxReserve) windowMaxReserve = r;
        if (r > blockMaxReserve) blockMaxReserve = r;
        vm.prank(a);
        try vault.mint(1, address(usdt), amt, 0) {
            mintsOk++;
            if (vault.collateralRatioBps(1) < 15_000) vBelowFloor++;
            uint256 net = (amt - (amt * 30 + 9_999) / 10_000) * 1e12;
            windowUsed += net;
            blockUsed += net;
            if (windowUsed > windowMaxReserve * 25 / 100 + 1e12) vWindowOverCap++;
            if (blockUsed > blockMaxReserve / 10 + 1e12) vBlockOverCap++;
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            if (
                s == BasketVault.MintWindowCapExceeded.selector || s == BasketVault.MintBlockCapExceeded.selector
                    || s == BasketVault.MintCoverageFloor.selector
            ) mintsLimited++;
            else vUnexpectedMintRevert++;
        }
    }

    function redeem(uint256 who, uint256 frac) external {
        address a = actors[who % 3];
        uint256 bal = coin.balanceOf(a);
        if (bal == 0) return;
        uint256 amt = bal * bound(frac, 1, 100) / 100;
        vm.prank(a);
        try vault.redeem(1, address(usdt), amt, 0) {} catch {}
    }

    function topUp(uint256 amt) external {
        amt = bound(amt, 1e6, 200_000e6);
        vm.prank(owner);
        vault.topUpReserve(1, address(usdt), amt);
    }

    function moveWorkingPrice(uint256 bps) external {
        bps = bound(bps, 9_700, 10_300);
        vm.prank(owner);
        try vault.setWorkingPrice(1, 1e18 * bps / 10_000) {} catch {}
    }

    function advance(uint256 secs) external {
        secs = bound(secs, 1, 2 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1 + secs / 2);
    }
}

contract MintLimitsInvariantTest is Test {
    BasketVault vault;
    BasketToken coin;
    MockStable usdt;
    MintLimitHandler h;
    address owner = makeAddr("anton");

    function setUp() public {
        vm.warp(1792368000);
        usdt = new MockStable("Tether USD", "USDT", 6);
        MockStable usdc = new MockStable("USD Coin", "USDC", 6);
        vault =
            new BasketVault(owner, makeAddr("treasury"), address(usdt), address(usdc), 50e18, address(0), address(0));
        coin = new BasketToken("BasketCoin", "BKT", owner);
        vm.startPrank(owner);
        coin.grantRole(coin.MINTER_ROLE(), address(vault));
        vault.addBasket(1, coin, 1e18);
        vm.stopPrank();
        address[3] memory a = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 3; ++i) {
            usdt.mint(a[i], 1e12 * 1e6);
            vm.prank(a[i]);
            usdt.approve(address(vault), type(uint256).max);
        }
        usdt.mint(owner, 1e12 * 1e6);
        vm.startPrank(owner);
        usdt.approve(address(vault), type(uint256).max);
        vault.topUpReserve(1, address(usdt), 300_000e6);
        vault.mint(1, address(usdt), 1_000_000e6, 0); // genesis ~156%
        vm.stopPrank();
        h = new MintLimitHandler(vault, coin, usdt, owner, a);
        targetContract(address(h));
    }

    function invariant_MintNeverBelowFloor() public view {
        assertEq(h.vBelowFloor(), 0);
    }

    function invariant_WindowAndBlockCaps() public view {
        assertEq(h.vWindowOverCap(), 0);
        assertEq(h.vBlockOverCap(), 0);
    }

    function invariant_OnlyLimitReverts() public view {
        assertEq(h.vUnexpectedMintRevert(), 0);
    }

    function invariant_SolventVsLiabilityAtP() public view {
        // резерв >= supply * P * min(cov) — мягкая проверка: покрытие не ниже 115% порога выкупа при минтах
        if (coin.totalSupply() == 0) return;
        assertGe(vault.collateralRatioBps(1), 11_500);
    }
}
