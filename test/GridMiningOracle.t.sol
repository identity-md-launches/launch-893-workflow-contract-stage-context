// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GridFixture} from "./helpers/GridFixture.sol";
import {GridMining} from "../src/GridMining.sol";

contract GridMiningOracleTest is GridFixture {
    function test_failedRequestRollsBackAndCanRetryBeforeDeadline() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        vm.warp(game.getRound(id).closesAt);
        uint256 deadline = game.getRound(id).deadline;
        vrf.configure(true, false, 0);
        vm.expectRevert("VRF unavailable");
        game.closeRound(id);
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Open));
        assertEq(game.getRound(id).deadline, deadline);
        assertEq(game.getRound(id).requestId, 0);
        assertEq(vrf.lastRequestId(), 0);
        vrf.configure(false, false, 0);
        game.closeRound(id);
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Requested));
        _assertAccounting();
    }

    function test_requestFailureOrMissingKeeperEventuallyRefunds() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 3);
        vm.warp(game.getRound(id).deadline);
        vm.expectRevert(GridMining.DeadlinePassed.selector);
        game.closeRound(id);
        game.expireRound(id);
        _claim(id, ALICE);
        assertEq(ALICE.balance, 100 ether);
        assertEq(game.availableRewards(), FUND);
        vm.expectRevert(GridMining.WrongState.selector);
        game.expireRound(id);
        _assertAccounting();
    }

    function test_missingFulfillmentRefundsAtExactDeadline() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        vm.warp(game.getRound(id).deadline - 1);
        vm.expectRevert(GridMining.TooEarly.selector);
        game.expireRound(id);
        vm.warp(block.timestamp + 1);
        vrf.fulfill(requestId, 0); // Late callback cannot race expiry, even when it is mined first.
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Requested));
        game.expireRound(id);
        vrf.fulfill(requestId, 0);
        vm.expectRevert(GridMining.WrongState.selector);
        game.settleRound(id);
        _claim(id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.NothingToClaim.selector);
        game.claim(id, payable(ALICE));
        assertEq(ALICE.balance, 100 ether);
        _assertAccounting();
    }

    function test_timelyFulfillmentCannotBeCancelledEvenIfSettlementIsDelayed() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        vm.warp(game.getRound(id).deadline - 1);
        vrf.fulfill(requestId, 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(GridMining.WrongState.selector);
        game.expireRound(id);
        game.settleRound(id);
        _claim(id, ALICE);
        assertEq(token.balanceOf(ALICE), REWARD);
    }

    function test_callbackRequiresCoordinator() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        uint256[] memory words = new uint256[](1);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.UnauthorizedCoordinator.selector);
        game.rawFulfillRandomWords(requestId, words);
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Requested));
    }

    function test_unknownMalformedAndDuplicateCallbacksCannotChangeOutcome() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        uint256[] memory words = new uint256[](1);
        vrf.deliver(address(game), 0, words);
        vrf.deliver(address(game), 999, words);
        vrf.deliver(address(game), requestId, new uint256[](0));
        vrf.deliver(address(game), requestId, new uint256[](2));
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Requested));
        vrf.fulfill(requestId, 0);
        vrf.fulfill(requestId, 1);
        assertEq(game.getRound(id).randomWord, 0);
        game.settleRound(id);
        vrf.fulfill(requestId, 2);
        assertEq(game.getRound(id).winningTile, 0);
        vm.expectRevert(GridMining.WrongState.selector);
        game.settleRound(id);
    }

    function test_oldRequestCannotAffectSubsequentRound() public {
        uint256 first = game.startRound();
        _enter(first, ALICE, 1);
        uint256 oldRequest = _close(first);
        vm.warp(game.getRound(first).deadline);
        game.expireRound(first);
        uint256 next = game.startRound();
        _enter(next, BOB, 2);
        uint256 newRequest = _close(next);
        vrf.fulfill(oldRequest, 0);
        assertEq(uint256(game.getRound(next).state), uint256(GridMining.State.Requested));
        vrf.fulfill(newRequest, 1);
        game.settleRound(next);
        _claim(first, ALICE);
        _claim(next, BOB);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), REWARD);
        _assertAccounting();
    }

    function test_rejectsZeroOrReusedRequestIds() public {
        uint256 first = game.startRound();
        _enter(first, ALICE, 1);
        vm.warp(game.getRound(first).closesAt);
        vrf.configure(false, true, 0);
        vm.expectRevert(GridMining.InvalidRequestId.selector);
        game.closeRound(first);
        vrf.configure(false, false, 0);
        game.closeRound(first);
        uint256 oldRequest = game.getRound(first).requestId;
        vrf.fulfill(oldRequest, 0);
        game.settleRound(first);
        uint256 next = game.startRound();
        _enter(next, ALICE, 1);
        vm.warp(game.getRound(next).closesAt);
        vrf.configure(false, true, oldRequest);
        vm.expectRevert(GridMining.InvalidRequestId.selector);
        game.closeRound(next);
        assertEq(game.requestRound(oldRequest), first);
        assertEq(uint256(game.getRound(next).state), uint256(GridMining.State.Open));
    }

    function test_underfundedCallbackExecutionLeavesTimeoutRecovery() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        assertFalse(vrf.fulfillWithGas(requestId, 42, 1_000));
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Requested));
        vm.warp(game.getRound(id).deadline);
        game.expireRound(id);
        _claim(id, ALICE);
        assertEq(ALICE.balance, 100 ether);
    }
}

contract GridMiningCallbackGasTest is GridFixture {
    uint256 private requestId;

    function setUp() public override {
        super.setUp();
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        requestId = _close(id);
    }

    function test_callbackFitsMinimumConfiguredGas() public {
        // Setup is a separate call; do not pre-read the consumer's storage in this test.
        assertTrue(vrf.fulfillWithGas(requestId, type(uint256).max, 100_000));
        assertEq(uint256(game.getRound(1).state), uint256(GridMining.State.Ready));
    }
}
