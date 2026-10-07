// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev A closed set of holders lets the ledger account for every unit of the launch supply.
contract LaunchTokenLedgerHandler is Test {
    LaunchToken public immutable token;
    uint256 public constant SUPPLY = 1e27;
    uint256 public constant ACTORS = 4;
    mapping(uint256 => uint256) public balances;
    mapping(uint256 => mapping(uint256 => uint256)) public allowances;

    constructor(LaunchToken token_) {
        token = token_;
        balances[0] = SUPPLY;
    }

    function actor(uint256 index) public pure returns (address) {
        return address(uint160(0xF000 + index));
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(actor(from));
        assertTrue(token.transfer(actor(to), amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amountSeed, bool infinite) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 amount = infinite ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        vm.prank(actor(owner));
        assertTrue(token.approve(actor(spender), amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 allowed = allowances[owner][spender];
        uint256 maximum = balances[owner] < allowed ? balances[owner] : allowed;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(actor(spender));
        assertTrue(token.transferFrom(actor(owner), actor(to), amount));
        balances[owner] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
    }

    function overspend(uint8 ownerSeed, uint8 spenderSeed, bool viaAllowance) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 amount = balances[owner] + 1;
        if (viaAllowance) {
            // Ensure the balance failure occurs AFTER allowance spending; the entire call must roll back.
            vm.prank(actor(owner));
            token.approve(actor(spender), amount);
            allowances[owner][spender] = amount;
            vm.prank(actor(spender));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actor(owner), balances[owner], amount
                )
            );
            token.transferFrom(actor(owner), actor(spender), amount);
        } else {
            vm.prank(actor(owner));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actor(owner), balances[owner], amount
                )
            );
            token.transfer(actor(spender), amount);
        }
    }

    function exceedAllowance(uint8 ownerSeed, uint8 spenderSeed) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 allowed = allowances[owner][spender];
        if (allowed == type(uint256).max) return;
        vm.prank(actor(spender));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actor(spender), allowed, allowed + 1
            )
        );
        token.transferFrom(actor(owner), actor(spender), allowed + 1);
    }

    function rejectZeroRecipient(uint8 ownerSeed, uint8 spenderSeed) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        vm.prank(actor(spender));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(actor(owner), address(0), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    LaunchTokenLedgerHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new LaunchTokenLedgerHandler(token);
        token.transfer(handler.actor(0), 1e27);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.overspend.selector;
        selectors[4] = handler.exceedAllowance.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAndAllowancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actor(i));
            assertEq(balance, handler.balances(i), "holder balance differs from recorded transfers");
            sum += balance;
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(handler.actor(i), handler.actor(j)), handler.allowances(i, j));
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_fullSupplyRoundTripAndRevokedAllowance() public {
        handler.approve(0, 1, 1e27, false);
        handler.transferFrom(0, 1, 2, 1e27);
        handler.transfer(2, 0, 1e27);
        handler.approve(0, 1, 1e27, true);
        handler.transferFrom(0, 1, 0, 1e27); // Self-transfer still checks authorization.
        handler.approve(0, 1, 0, false);
        handler.exceedAllowance(0, 1);
        handler.overspend(0, 1, true);
        invariant_balancesAndAllowancesMatchIndependentLedger();
        assertEq(token.balanceOf(handler.actor(0)), 1e27);
    }
}
