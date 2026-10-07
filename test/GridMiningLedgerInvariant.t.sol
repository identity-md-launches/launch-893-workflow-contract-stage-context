// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GridMining} from "src/GridMining.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockVRFCoordinator} from "./helpers/MockVRFCoordinator.sol";

contract LedgerRejectRecipient {
    receive() external payable {
        revert("reject payment");
    }
}

/// @dev Records tickets and expected outcomes from inputs, never from claimable or contract balances.
contract GridMiningLedgerHandler is Test {
    struct Record {
        GridMining.State state;
        uint256 closesAt;
        uint256 deadline;
        uint256 requestId;
        uint256 word;
        uint256 tickets;
        uint256 pot;
        uint256 winners;
        uint256 claims;
        uint256 nativePaid;
        uint256 goldPaid;
    }

    uint128 private constant PRICE = 7;
    uint128 private constant REWARD = 11;
    uint256 private constant ACTORS = 4;
    uint32 private constant ALL = (uint32(1) << 25) - 1;
    GridMining private immutable game;
    LaunchToken private immutable token;
    MockVRFCoordinator private immutable vrf;
    LedgerRejectRecipient private immutable reject;
    mapping(uint256 => Record) private records;
    mapping(uint256 => mapping(uint256 => uint32)) private masks;
    mapping(uint256 => mapping(uint256 => uint256)) private deposits;
    mapping(uint256 => mapping(uint256 => bool)) private redeemed;
    uint256 public rounds;
    uint256 private requests;
    uint256 private available;
    uint256 private funding;
    uint256 private nativeIn;
    uint256 private nativeOut;
    uint256 private goldOut;
    uint256 public nativeSurplus;
    uint256 public goldSurplus;

    constructor(GridMining game_, LaunchToken token_, MockVRFCoordinator vrf_) {
        game = game_;
        token = token_;
        vrf = vrf_;
        reject = new LedgerRejectRecipient();
    }

    function _actor(uint256 index) private pure returns (address) {
        return address(uint160(0xE000 + index));
    }

    function fund(uint256 seed) public {
        uint256 amount = bound(seed, 1, 1000);
        token.approve(address(game), amount);
        game.fundRewards(amount);
        funding += amount;
        available += amount;
    }

    function start() public {
        GridMining.State state = records[rounds].state;
        if (rounds != 0 && state != GridMining.State.Settled && state != GridMining.State.Refundable) return;
        if (available < REWARD) {
            vm.expectRevert(GridMining.InsufficientRewards.selector);
            game.startRound();
            return;
        }
        assertEq(game.startRound(), ++rounds);
        Record storage r = records[rounds];
        r.state = GridMining.State.Open;
        r.closesAt = block.timestamp + 30;
        r.deadline = r.closesAt + 3600;
        available -= REWARD;
    }

    function enter(uint8 actorSeed, uint32 seed) public {
        Record storage r = records[rounds];
        if (r.state != GridMining.State.Open) return;
        uint256 player = actorSeed % ACTORS;
        uint32 tiles = seed & ALL & ~masks[rounds][player];
        if (tiles == 0) return;
        uint256 tickets;
        for (uint256 i; i < 25; ++i) {
            if ((tiles & (uint256(1) << i)) != 0) ++tickets;
        }
        uint256 amount = tickets * PRICE;
        address actor = _actor(player);
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        game.enter{value: amount}(rounds, tiles);
        masks[rounds][player] |= tiles;
        deposits[rounds][player] += amount;
        r.tickets += tickets;
        r.pot += amount;
        nativeIn += amount;
    }

    /// @dev Progress advances to an actual boundary, avoiding a campaign dominated by no-op calls.
    function progress(uint256 word, uint8 mode) public {
        Record storage r = records[rounds];
        if (r.state == GridMining.State.Open) {
            if (mode % 4 == 0) {
                vm.warp(r.deadline);
                game.expireRound(rounds);
                _refund(r);
            } else {
                vm.warp(r.closesAt + (mode % 4 == 2 ? 3599 : 0));
                game.closeRound(rounds);
                if (r.tickets == 0) {
                    _refund(r);
                } else {
                    r.state = GridMining.State.Requested;
                    r.requestId = ++requests;
                    r.deadline = block.timestamp + 3600;
                }
            }
        } else if (r.state == GridMining.State.Requested) {
            if (mode % 4 == 0) {
                vm.warp(r.deadline);
                vrf.fulfill(r.requestId, word);
                assertEq(uint256(game.getRound(rounds).state), uint256(GridMining.State.Requested));
                game.expireRound(rounds);
                _refund(r);
            } else if (mode % 4 == 1) {
                vrf.deliver(address(game), r.requestId, new uint256[](0));
            } else {
                vm.warp(r.deadline - 1);
                vrf.fulfill(r.requestId, word);
                r.word = word;
                r.state = GridMining.State.Ready;
            }
        } else if (r.state == GridMining.State.Ready) {
            // Ready results remain final even far beyond the former fulfillment deadline.
            vm.warp(block.timestamp + 8 days);
            game.settleRound(rounds);
            for (uint256 i; i < ACTORS; ++i) {
                if ((masks[rounds][i] & (uint256(1) << (r.word % 25))) != 0) ++r.winners;
            }
            if (r.winners == 0) _refund(r);
            else r.state = GridMining.State.Settled;
        }
    }

    function _refund(Record storage r) private {
        r.state = GridMining.State.Refundable;
        available += REWARD;
    }

    function _owed(uint256 id, uint256 player) private view returns (uint256 nativeAmount, uint256 goldAmount) {
        if (redeemed[id][player]) return (0, 0);
        Record storage r = records[id];
        if (r.state == GridMining.State.Refundable) return (deposits[id][player], 0);
        if (r.state != GridMining.State.Settled || (masks[id][player] & (uint256(1) << (r.word % 25))) == 0) {
            return (0, 0);
        }
        nativeAmount = r.pot / r.winners;
        goldAmount = REWARD / r.winners;
        if (r.claims == r.winners - 1) {
            nativeAmount += r.pot % r.winners;
            goldAmount += REWARD % r.winners;
        }
    }

    function claim(uint256 roundSeed, uint8 actorSeed, uint8 recipientSeed) public {
        if (rounds == 0) return;
        _claim(bound(roundSeed, 1, rounds), actorSeed % ACTORS, _actor(recipientSeed % ACTORS));
    }

    function _claim(uint256 id, uint256 player, address recipient) private {
        (uint256 nativeAmount, uint256 goldAmount) = _owed(id, player);
        (uint256 quotedNative, uint256 quotedGold) = game.claimable(id, _actor(player));
        assertEq(quotedNative, nativeAmount, "native entitlement");
        assertEq(quotedGold, goldAmount, "Gold entitlement");
        uint256 nativeBefore = recipient.balance;
        uint256 goldBefore = token.balanceOf(recipient);
        vm.prank(_actor(player));
        if (nativeAmount == 0 && goldAmount == 0) {
            vm.expectRevert(GridMining.NothingToClaim.selector);
            game.claim(id, payable(recipient));
            return;
        }
        game.claim(id, payable(recipient));
        assertEq(recipient.balance - nativeBefore, nativeAmount);
        assertEq(token.balanceOf(recipient) - goldBefore, goldAmount);
        redeemed[id][player] = true;
        Record storage r = records[id];
        if (r.state == GridMining.State.Settled) ++r.claims;
        r.nativePaid += nativeAmount;
        r.goldPaid += goldAmount;
        nativeOut += nativeAmount;
        goldOut += goldAmount;
    }

    function donate(uint64 nativeAmount, uint64 goldAmount) public {
        // Models an unsolicited native transfer without changing the accounting under test.
        vm.deal(address(game), address(game).balance + nativeAmount);
        token.transfer(address(game), goldAmount);
        nativeSurplus += nativeAmount;
        goldSurplus += goldAmount;
    }

    function failedDelivery(uint256 roundSeed, uint8 actorSeed) public {
        if (rounds == 0) return;
        uint256 id = bound(roundSeed, 1, rounds);
        uint256 player = actorSeed % ACTORS;
        (uint256 nativeAmount, uint256 goldAmount) = _owed(id, player);
        if (nativeAmount == 0) return;
        vm.prank(_actor(player));
        vm.expectRevert(GridMining.TransferFailed.selector);
        game.claim(id, payable(address(reject)));
        assertFalse(game.claimed(id, _actor(player)));
        (uint256 afterNative, uint256 afterGold) = game.claimable(id, _actor(player));
        assertEq(afterNative, nativeAmount);
        assertEq(afterGold, goldAmount);
        assertEq(token.balanceOf(address(reject)), 0);
    }

    function replayOrForge(uint256 roundSeed, uint256 word) public {
        if (rounds == 0) return;
        uint256 id = bound(roundSeed, 1, rounds);
        Record storage r = records[id];
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(_actor(0));
        vm.expectRevert(GridMining.UnauthorizedCoordinator.selector);
        game.rawFulfillRandomWords(r.requestId, words);
        if (r.state != GridMining.State.Requested) vrf.deliver(address(game), r.requestId, words);
        if (r.state == GridMining.State.Settled || r.state == GridMining.State.Refundable) {
            vm.expectRevert(GridMining.WrongState.selector);
            game.closeRound(id);
            vm.expectRevert(GridMining.WrongState.selector);
            game.expireRound(id);
            vm.expectRevert(GridMining.WrongState.selector);
            game.settleRound(id);
        }
    }

    function assertLedger() public view {
        uint256 nativeOwed;
        uint256 goldReserved;
        assertEq(game.currentRound(), rounds);
        for (uint256 id = 1; id <= rounds; ++id) {
            Record storage expected = records[id];
            GridMining.Round memory actual = game.getRound(id);
            assertEq(uint256(actual.state), uint256(expected.state), "round state changed unexpectedly");
            assertEq(actual.entries, expected.tickets);
            assertEq(actual.pot, expected.pot);
            assertEq(actual.closesAt, expected.closesAt);
            assertEq(actual.deadline, expected.deadline);
            assertEq(actual.requestId, expected.requestId);
            assertEq(actual.randomWord, expected.word);
            if (expected.requestId != 0) assertEq(game.requestRound(expected.requestId), id);
            assertEq(actual.winners, expected.winners);
            assertEq(actual.claimedWinners, expected.claims);
            if (expected.state == GridMining.State.Settled || expected.state == GridMining.State.Refundable) {
                assertEq(actual.winningTile, expected.word % 25);
            }
            uint256 nativeRemaining = expected.pot - expected.nativePaid;
            uint256 goldRemaining = expected.state == GridMining.State.Refundable ? 0 : REWARD - expected.goldPaid;
            assertEq(actual.remainingNative, nativeRemaining);
            assertEq(actual.remainingGold, goldRemaining);
            nativeOwed += nativeRemaining;
            goldReserved += goldRemaining;
            for (uint256 player; player < ACTORS; ++player) {
                assertEq(game.selections(id, _actor(player)), masks[id][player]);
                assertEq(game.claimed(id, _actor(player)), redeemed[id][player]);
                (uint256 nativeAmount, uint256 goldAmount) = _owed(id, player);
                (uint256 quotedNative, uint256 quotedGold) = game.claimable(id, _actor(player));
                assertEq(quotedNative, nativeAmount);
                assertEq(quotedGold, goldAmount);
            }
        }
        assertEq(game.nativeLiability(), nativeOwed);
        assertEq(game.reservedRewards(), goldReserved);
        assertEq(game.availableRewards(), available);
        assertEq(nativeIn, nativeOut + nativeOwed);
        assertEq(funding, goldOut + goldReserved + available);
        assertEq(address(game).balance, nativeOwed + nativeSurplus);
        assertEq(token.balanceOf(address(game)), goldReserved + available + goldSurplus);
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev Liveness check: every sequence ends by recovering all independently computed entitlements.
    function drain() external {
        progress(0, 0); // Expires Open/Requested or settles Ready; terminal rounds are unchanged.
        for (uint256 id = 1; id <= rounds; ++id) {
            for (uint256 player; player < ACTORS; ++player) {
                _claim(id, player, _actor(player));
            }
        }
        assertLedger();
        assertEq(game.nativeLiability(), 0);
        assertEq(game.reservedRewards(), 0);
        assertEq(address(game).balance, nativeSurplus);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract GridMiningLedgerInvariantTest is Test {
    GridMiningLedgerHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        LaunchToken token = new LaunchToken();
        MockVRFCoordinator vrf = new MockVRFCoordinator();
        GridMining game =
            new GridMining(address(token), address(vrf), bytes32(uint256(1)), 1, 3, 100_000, 30, 3600, 7, 11);
        handler = new GridMiningLedgerHandler(game, token, vrf);
        token.transfer(address(handler), 1e27);
        handler.fund(1000);

        // Begin with both prize and refund liabilities, plus an open round. No invariant is vacuous.
        handler.start();
        handler.enter(0, 3);
        handler.enter(1, 1);
        handler.enter(2, 1);
        handler.progress(0, 1);
        handler.progress(0, 2);
        handler.progress(0, 1);
        handler.start();
        handler.enter(3, (uint32(1) << 25) - 1);
        handler.progress(0, 0);
        handler.start();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.start.selector;
        selectors[1] = handler.enter.selector;
        selectors[2] = handler.progress.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.fund.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.failedDelivery.selector;
        selectors[7] = handler.replayOrForge.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_roundsAndIndividualClaimsMatchRecordedInputs() public view {
        handler.assertLedger();
    }

    function afterInvariant() public {
        handler.drain();
    }

    function test_handlerTraversesLateMalformedEmptyAndWinningOutcomes() public {
        handler.failedDelivery(1, 0);
        handler.donate(3, 5);
        handler.claim(1, 1, 3);
        handler.enter(0, 1);
        handler.progress(0, 2); // Delayed request.
        handler.progress(0, 1); // Malformed callback, then timely callback selecting an empty tile.
        handler.progress(24, 2);
        handler.progress(0, 1);
        handler.replayOrForge(3, 0);
        handler.start();
        handler.enter(1, 1);
        handler.progress(0, 1);
        handler.progress(0, 0); // Expired callback cannot convert a refund into a prize.
        handler.start();
        handler.progress(0, 1); // Empty round.
        handler.assertLedger();
        handler.drain();
    }
}
