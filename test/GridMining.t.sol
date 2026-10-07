// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GridFixture} from "./helpers/GridFixture.sol";
import {GridMining} from "../src/GridMining.sol";
import {IVRFCoordinator} from "../src/interfaces/IVRFCoordinator.sol";

contract GridMiningTest is GridFixture {
    function test_initialConfigurationAndFunding() public view {
        assertEq(address(game.gold()), address(token));
        assertEq(address(game.coordinator()), address(vrf));
        assertEq(game.availableRewards(), FUND);
        assertEq(game.reservedRewards(), 0);
        assertEq(game.currentRound(), 0);
        assertEq(game.entryPrice(), PRICE);
        assertEq(game.rewardPerRound(), REWARD);
        _assertAccounting();
    }

    function test_reservesRewardBeforeAcceptingEntries() public {
        uint256 id = game.startRound();
        assertEq(id, 1);
        assertEq(game.availableRewards(), FUND - REWARD);
        assertEq(game.reservedRewards(), REWARD);
        assertEq(game.getRound(id).closesAt, block.timestamp + DURATION);
        vm.expectRevert(GridMining.WrongState.selector);
        game.startRound();
        _assertAccounting();
    }

    function test_canAddDistinctTilesInSeparateCalls() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _enter(id, ALICE, 6);
        _enter(id, BOB, 2);
        assertEq(game.selections(id, ALICE), 7);
        assertEq(game.tileEntries(id, 0), 1);
        assertEq(game.tileEntries(id, 1), 2);
        assertEq(game.tileEntries(id, 2), 1);
        assertEq(game.getRound(id).entries, 4);
        assertEq(game.getRound(id).pot, 4 * PRICE);
        _assertAccounting();
    }

    function test_rejectsDuplicateTilesAtomically() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.DuplicateTile.selector);
        game.enter{value: 2 * PRICE}(id, 3);
        assertEq(game.selections(id, ALICE), 1);
        assertEq(game.tileEntries(id, 1), 0);
        assertEq(game.nativeLiability(), PRICE);
    }

    function test_rejectsInvalidTilesAndPayment() public {
        uint256 id = game.startRound();
        vm.startPrank(ALICE);
        vm.expectRevert(GridMining.InvalidTiles.selector);
        game.enter(id, 0);
        vm.expectRevert(GridMining.InvalidTiles.selector);
        game.enter{value: PRICE}(id, uint32(1) << 25);
        vm.expectRevert(GridMining.IncorrectPayment.selector);
        game.enter{value: PRICE - 1}(id, 1);
        vm.expectRevert(GridMining.IncorrectPayment.selector);
        game.enter{value: PRICE + 1}(id, 1);
        vm.stopPrank();
        assertEq(game.getRound(id).entries, 0);
    }

    function test_closingBoundaryRejectsLateEntry() public {
        uint256 id = game.startRound();
        vm.warp(game.getRound(id).closesAt - 1);
        _enter(id, ALICE, 1);
        vm.expectRevert(GridMining.TooEarly.selector);
        game.closeRound(id);
        vm.warp(block.timestamp + 1);
        vm.prank(BOB);
        vm.expectRevert(GridMining.DeadlinePassed.selector);
        game.enter{value: PRICE}(id, 1);
        game.closeRound(id);
        vm.prank(BOB);
        vm.expectRevert(GridMining.WrongState.selector);
        game.enter{value: PRICE}(id, 1);
    }

    function test_emptyRoundDoesNotSpendOracleFunds() public {
        uint256 id = game.startRound();
        _close(id);
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Refundable));
        assertEq(vrf.lastRequestId(), 0);
        assertEq(game.availableRewards(), FUND);
        assertEq(game.reservedRewards(), 0);
        assertEq(game.startRound(), 2);
    }

    function test_requestUsesExactSubscriptionABIAndLinkBilling() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        uint256 requestId = _close(id);
        IVRFCoordinator.RandomWordsRequest memory request = vrf.lastRequest();
        assertEq(request.keyHash, KEY);
        assertEq(request.subId, 1);
        assertEq(request.requestConfirmations, 3);
        assertEq(request.callbackGasLimit, 100_000);
        assertEq(request.numWords, 1);
        assertEq(request.extraArgs, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false));
        assertEq(game.requestRound(requestId), id);
        assertEq(game.getRound(id).deadline, block.timestamp + TIMEOUT);
        vm.expectRevert(GridMining.WrongState.selector);
        game.closeRound(id);
    }

    function test_winnersShareWholePotAndGoldLoserGetsNothing() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _enter(id, BOB, 3);
        _enter(id, CAROL, 2);
        _settle(id, 25); // 25 % 25 == tile 0; zero is also a valid random word.
        assertEq(game.getRound(id).winners, 2);
        (uint256 nativeAmount, uint256 goldAmount) = game.claimable(id, ALICE);
        assertEq(nativeAmount, 2 * PRICE);
        assertEq(goldAmount, REWARD / 2);
        vm.prank(CAROL);
        vm.expectRevert(GridMining.NothingToClaim.selector);
        game.claim(id, payable(CAROL));
        _claim(id, ALICE);
        _claim(id, BOB);
        assertEq(ALICE.balance, 100 ether + PRICE);
        assertEq(BOB.balance, 100 ether);
        assertEq(CAROL.balance, 100 ether - PRICE);
        assertEq(token.balanceOf(ALICE), REWARD / 2);
        assertEq(token.balanceOf(BOB), REWARD / 2);
        assertEq(game.nativeLiability(), 0);
        assertEq(game.reservedRewards(), 0);
        _assertAccounting();
    }

    function test_lastWinnerReceivesDustAndNoFundsAreStranded() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 3);
        _enter(id, BOB, 1);
        _enter(id, CAROL, 1);
        _settle(id, 0);
        _claim(id, BOB);
        _claim(id, CAROL);
        (uint256 nativeAmount, uint256 goldAmount) = game.claimable(id, ALICE);
        assertEq(nativeAmount, 4 * uint256(PRICE) - 2 * (4 * uint256(PRICE) / 3));
        assertEq(goldAmount, uint256(REWARD) - 2 * (uint256(REWARD) / 3));
        _claim(id, ALICE);
        assertEq(address(game).balance, 0);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL), REWARD);
        _assertAccounting();
    }

    function test_emptyWinningTileRefundsAllEntriesAndRecyclesGold() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 3);
        _enter(id, BOB, 2);
        _settle(id, 24);
        assertEq(uint256(game.getRound(id).state), uint256(GridMining.State.Refundable));
        assertEq(game.availableRewards(), FUND);
        _claim(id, ALICE);
        _claim(id, BOB);
        assertEq(ALICE.balance, 100 ether);
        assertEq(BOB.balance, 100 ether);
        assertEq(token.balanceOf(ALICE), 0);
        _assertAccounting();
    }

    function test_claimIsSingleUseAndCanRedirectToAnotherRecipient() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 0);
        vm.prank(BOB);
        vm.expectRevert(GridMining.NothingToClaim.selector);
        game.claim(id, payable(BOB));
        vm.prank(ALICE);
        game.claim(id, payable(BOB));
        assertEq(token.balanceOf(BOB), REWARD);
        assertEq(BOB.balance, 100 ether + PRICE);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.NothingToClaim.selector);
        game.claim(id, payable(ALICE));
        (uint256 nativeAmount, uint256 goldAmount) = game.claimable(id, ALICE);
        assertEq(nativeAmount + goldAmount, 0);
    }

    function test_invalidRecipientsLeaveClaimIntact() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 0);
        vm.startPrank(ALICE);
        vm.expectRevert(GridMining.InvalidRecipient.selector);
        game.claim(id, payable(address(0)));
        vm.expectRevert(GridMining.InvalidRecipient.selector);
        game.claim(id, payable(address(game)));
        vm.stopPrank();
        assertFalse(game.claimed(id, ALICE));
    }

    function test_oldClaimsDoNotBlockNewRoundsOrSpendNewReserves() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 0);
        uint256 next = game.startRound();
        _enter(next, BOB, 2);
        _claim(id, ALICE);
        assertEq(game.nativeLiability(), PRICE);
        assertEq(game.reservedRewards(), REWARD);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.WrongState.selector);
        game.enter{value: PRICE}(id, 2);
        _assertAccounting();
    }

    function test_exhaustedRewardReserveStopsNewRounds() public {
        GridMining one =
            new GridMining(address(token), address(vrf), KEY, 1, 3, 100_000, DURATION, TIMEOUT, PRICE, REWARD);
        vm.expectRevert(GridMining.InsufficientRewards.selector);
        one.startRound();
        token.approve(address(one), REWARD);
        one.fundRewards(REWARD);
        one.startRound();
        vm.prank(ALICE);
        one.enter{value: PRICE}(1, 1);
        vm.warp(one.getRound(1).closesAt);
        one.closeRound(1);
        vrf.fulfill(one.getRound(1).requestId, 0);
        one.settleRound(1);
        vm.expectRevert(GridMining.InsufficientRewards.selector);
        one.startRound();
        vm.prank(ALICE);
        one.claim(1, payable(ALICE));
        assertEq(token.balanceOf(address(one)), 0);
    }

    function test_invalidRoundOperationsAndEarlyClaimsRevert() public {
        vm.expectRevert(GridMining.WrongState.selector);
        game.enter(0, 1);
        vm.expectRevert(GridMining.WrongState.selector);
        game.closeRound(8);
        vm.expectRevert(GridMining.WrongState.selector);
        game.settleRound(8);
        vm.expectRevert(GridMining.WrongState.selector);
        game.expireRound(8);
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.NothingToClaim.selector);
        game.claim(id, payable(ALICE));
        vm.expectRevert(GridMining.WrongState.selector);
        game.settleRound(id);
        vm.expectRevert(GridMining.TooEarly.selector);
        game.expireRound(id);
    }

    function test_directNativeTransferIsRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(game).call{value: 1}("");
        assertFalse(ok);
        _assertAccounting();
    }

    function test_zeroFundingAndUnapprovedFundingRevert() public {
        vm.expectRevert(GridMining.InvalidAmount.selector);
        game.fundRewards(0);
        vm.prank(ALICE);
        vm.expectRevert();
        game.fundRewards(1);
        assertEq(game.availableRewards(), FUND);
    }

    function testFuzz_conservationAcrossGridOutcomes(uint32 a, uint32 b, uint32 c, uint256 word, uint8 order) public {
        uint32 mask = game.ALL_TILES();
        a = (a & mask) | 1;
        b = (b & mask) | 2;
        c = (c & mask) | 4;
        uint256 id = game.startRound();
        _enter(id, ALICE, a);
        _enter(id, BOB, b);
        _enter(id, CAROL, c);
        _assertAccounting();
        _settle(id, word);
        bool refunded = game.getRound(id).state == GridMining.State.Refundable;
        address[3] memory players = [ALICE, BOB, CAROL];
        for (uint256 i; i < 3; ++i) {
            address player = players[(i + uint256(order)) % 3];
            (uint256 nativeAmount, uint256 goldAmount) = game.claimable(id, player);
            if (nativeAmount + goldAmount != 0) _claim(id, player);
            _assertAccounting();
        }
        assertEq(ALICE.balance + BOB.balance + CAROL.balance, 300 ether);
        assertEq(address(game).balance, 0);
        assertEq(game.reservedRewards(), 0);
        assertEq(game.availableRewards(), refunded ? FUND : FUND - REWARD);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL), refunded ? 0 : REWARD);
    }
}
