// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TestStablecoin, TestUSDT, TestUSDC} from "../../src/testnet/TestStablecoins.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {BasketVault} from "../../src/BasketVault.sol";
import {BasketToken} from "../../src/BasketToken.sol";

/// Тестнет-стейблы (кран) и скрипт деплоя.
contract TestnetTest is Test {
    event FaucetMinted(address indexed to, uint256 amount);

    TestUSDT internal usdt;
    TestUSDC internal usdc;
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdt = new TestUSDT();
        usdc = new TestUSDC();
    }

    function test_Metadata() public view {
        assertEq(usdt.decimals(), 6);
        assertEq(usdc.decimals(), 6);
        assertEq(usdt.symbol(), "tUSDT");
        assertEq(usdc.symbol(), "tUSDC");
        assertEq(usdt.FAUCET_LIMIT(), 10_000e6);
    }

    function test_Faucet_UpToLimit() public {
        vm.expectEmit(true, false, false, true, address(usdt));
        emit FaucetMinted(alice, 10_000e6);
        vm.prank(alice);
        usdt.faucet(10_000e6);
        vm.prank(alice);
        usdt.faucet(1);
        assertEq(usdt.balanceOf(alice), 10_000e6 + 1);
        assertEq(usdt.totalSupply(), 10_000e6 + 1);
    }

    function test_Faucet_RevertsAboveLimitOrZero() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestStablecoin.FaucetAmountInvalid.selector, 10_000e6 + 1, 10_000e6));
        usdc.faucet(10_000e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(TestStablecoin.FaucetAmountInvalid.selector, 0, 10_000e6));
        usdc.faucet(0);
        vm.stopPrank();
    }

    function testFuzz_Faucet(uint256 amount) public {
        vm.prank(alice);
        if (amount == 0 || amount > 10_000e6) {
            vm.expectRevert();
            usdt.faucet(amount);
        } else {
            usdt.faucet(amount);
            assertEq(usdt.balanceOf(alice), amount);
        }
    }

    function _runDeploy(address owner, string memory file)
        internal
        returns (Deploy.Deployed memory d, address deployer)
    {
        uint256 pk = uint256(keccak256("basketcoin-test-deployer"));
        deployer = vm.addr(pk);
        // Явный Config, без vm.setEnv: переменные окружения общие для параллельных тестов.
        d = new Deploy()
            .deploy(
                Deploy.Config({
                    deployerPk: pk,
                    owner: owner,
                    feeRecipient: makeAddr("treasury"),
                    minMintUsd: 50e18,
                    initialIndex: 1e18,
                    basketId: 1,
                    deploymentsFile: file
                })
            );
        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json, ".BasketVault"), d.vault);
        assertEq(vm.parseJsonAddress(json, ".BasketToken"), d.token);
        assertEq(vm.parseJsonAddress(json, ".vaultPendingOwner"), owner == deployer ? address(0) : owner);
        vm.removeFile(file);
    }

    function test_DeployScript_SameOwner() public {
        uint256 pk = uint256(keccak256("basketcoin-test-deployer"));
        (Deploy.Deployed memory d, address deployer) = _runDeploy(vm.addr(pk), "deployments/test-same.local.json");
        BasketVault vault = BasketVault(d.vault);
        BasketToken token = BasketToken(d.token);
        assertEq(vault.owner(), deployer);
        assertEq(vault.pendingOwner(), address(0));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(token.hasRole(token.MINTER_ROLE(), d.vault));
        assertEq(vault.feeRecipient(), makeAddr("treasury"));
        assertEq(vault.minMintUsd(), 50e18);
        (, uint256 index,,,, bool exists) = vault.baskets(1);
        assertTrue(exists);
        assertEq(index, 1e18);
    }

    function test_DeployScript_HandsOverToNewOwner() public {
        address newOwner = makeAddr("newOwner");
        (Deploy.Deployed memory d, address deployer) = _runDeploy(newOwner, "deployments/test-handover.local.json");
        BasketVault vault = BasketVault(d.vault);
        BasketToken token = BasketToken(d.token);
        assertEq(vault.owner(), deployer);
        assertEq(vault.pendingOwner(), newOwner);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), newOwner));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
        assertEq(vault.pendingOwner(), address(0));
    }
}
