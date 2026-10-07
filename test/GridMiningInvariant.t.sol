// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GridFixture} from "./helpers/GridFixture.sol";
import {GridMining} from "../src/GridMining.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockVRFCoordinator} from "./helpers/MockVRFCoordinator.sol";

contract GridHandler is Test {
    GridMining private immutable game;
    LaunchToken private immutable token;
    MockVRFCoordinator private immutable vrf;
    address[4] private actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public paidIn;
    uint256 public paidOut;
    uint256 public goldOut;
    uint256 public funded;

    constructor(GridMining game_, LaunchToken token_, MockVRFCoordinator vrf_) {
        game = game_;
        token = token_;
        vrf = vrf_;
    }

    function fund(uint96 seed) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(seed), 1, balance);
        token.approve(address(game), amount);
        game.fundRewards(amount);
        funded += amount;
    }

    function start() external {
        GridMining.State state = game.getRound(game.currentRound()).state;
        if (state != GridMining.State.None && state != GridMining.State.Settled && state != GridMining.State.Refundable)
        {
            return;
        }
        if (game.availableRewards() >= game.rewardPerRound()) game.startRound();
    }

    function enter(uint8 actorSeed, uint32 tiles) external {
        uint256 id = game.currentRound();
        GridMining.Round memory r = game.getRound(id);
        if (r.state != GridMining.State.Open || block.timestamp >= r.closesAt) return;
        address actor = actors[actorSeed % 4];
        tiles = tiles & game.ALL_TILES() & ~game.selections(id, actor);
        if (tiles == 0) return;
        uint256 amount = _count(tiles) * game.entryPrice();
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        game.enter{value: amount}(id, tiles);
        paidIn += amount;
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 1, game.oracleTimeout() + game.roundDuration()));
    }

    function close() external {
        uint256 id = game.currentRound();
        GridMining.Round memory r = game.getRound(id);
        if (r.state == GridMining.State.Open && block.timestamp >= r.closesAt && block.timestamp < r.deadline) {
            game.closeRound(id);
        }
    }

    function fulfill(uint256 word) external {
        GridMining.Round memory r = game.getRound(game.currentRound());
        if (r.state == GridMining.State.Requested) vrf.fulfill(r.requestId, word);
    }

    function settle() external {
        uint256 id = game.currentRound();
        if (game.getRound(id).state == GridMining.State.Ready) game.settleRound(id);
    }

    function expire() external {
        uint256 id = game.currentRound();
        GridMining.Round memory r = game.getRound(id);
        if (
            (r.state == GridMining.State.Open || r.state == GridMining.State.Requested) && block.timestamp >= r.deadline
        ) {
            game.expireRound(id);
        }
    }

    function claim(uint8 actorSeed, uint256 roundSeed) external {
        if (game.currentRound() == 0) return;
        uint256 id = bound(roundSeed, 1, game.currentRound());
        address actor = actors[actorSeed % 4];
        (uint256 nativeAmount, uint256 goldAmount) = game.claimable(id, actor);
        if (nativeAmount + goldAmount == 0) return;
        uint256 nativeBefore = actor.balance;
        uint256 goldBefore = token.balanceOf(actor);
        vm.prank(actor);
        game.claim(id, payable(actor));
        assertEq(actor.balance - nativeBefore, nativeAmount);
        assertEq(token.balanceOf(actor) - goldBefore, goldAmount);
        paidOut += nativeAmount;
        goldOut += goldAmount;
    }

    function _count(uint32 mask) private pure returns (uint256 count) {
        while (mask != 0) {
            mask &= mask - 1;
            ++count;
        }
    }
}

contract GridMiningInvariantTest is GridFixture {
    GridHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new GridHandler(game, token, vrf);
        token.transfer(address(handler), 10_000 ether);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = GridHandler.fund.selector;
        selectors[1] = GridHandler.start.selector;
        selectors[2] = GridHandler.enter.selector;
        selectors[3] = GridHandler.advance.selector;
        selectors[4] = GridHandler.close.selector;
        selectors[5] = GridHandler.fulfill.selector;
        selectors[6] = GridHandler.settle.selector;
        selectors[7] = GridHandler.expire.selector;
        selectors[8] = GridHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allCustodiedAssetsMatchLiabilities() public view {
        _assertAccounting();
        assertEq(handler.paidIn(), handler.paidOut() + game.nativeLiability());
        assertEq(FUND + handler.funded(), handler.goldOut() + game.availableRewards() + game.reservedRewards());
        uint256 nativeSum;
        uint256 goldSum;
        uint256 active;
        for (uint256 id = 1; id <= game.currentRound(); ++id) {
            GridMining.Round memory r = game.getRound(id);
            nativeSum += r.remainingNative;
            goldSum += r.remainingGold;
            assertEq(r.pot, r.entries * PRICE);
            assertLe(r.remainingNative, r.pot);
            assertLe(r.claimedWinners, r.winners);
            if (r.state == GridMining.State.Refundable) assertEq(r.remainingGold, 0);
            if (
                r.state == GridMining.State.Open || r.state == GridMining.State.Requested
                    || r.state == GridMining.State.Ready
            ) {
                ++active;
                assertEq(id, game.currentRound());
            }
        }
        assertEq(nativeSum, game.nativeLiability());
        assertEq(goldSum, game.reservedRewards());
        assertLe(active, 1);
    }
}
