// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Gold");
        assertEq(token.symbol(), "Gold");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndTransferFrom() public {
        token.transfer(ALICE, 20 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 7 ether));
        assertEq(token.allowance(ALICE, BOB), 3 ether);
        assertEq(token.balanceOf(ALICE), 13 ether);
        assertEq(token.balanceOf(BOB), 7 ether);
    }

    function test_infiniteAllowanceAndSelfTransfer() public {
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1 ether);
        assertEq(token.allowance(address(this), BOB), type(uint256).max);
        vm.prank(ALICE);
        token.transfer(ALICE, 1 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function test_rejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_rejectsInsufficientBalanceAndAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    function test_noAdminOrMintSelectorsEvenForDeployer() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            (bool ok,) = address(token).call(data);
            assertFalse(ok);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(address(this)), 1e27);
            assertEq(token.balanceOf(ALICE), 0);
        }
    }
}
