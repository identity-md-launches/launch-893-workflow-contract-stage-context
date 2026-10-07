// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GridMining} from "src/GridMining.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockVRFCoordinator} from "./helpers/MockVRFCoordinator.sol";

/// forge-config: default.fuzz.runs = 1000
contract GridMiningPropertiesTest is Test {
    LaunchToken private token;
    MockVRFCoordinator private vrf;
    uint32 private constant ALL = (uint32(1) << 25) - 1;

    struct Distribution {
        uint256 price;
        uint256 reward;
        uint256 pot;
        uint256 winners;
        uint256 tile;
        uint256 paidNative;
        uint256 paidGold;
        uint256 claimedWinners;
    }

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vrf = new MockVRFCoordinator();
    }

    function _newGame(uint128 price, uint128 reward) private returns (GridMining game) {
        game = new GridMining(address(token), address(vrf), bytes32(uint256(1)), 1, 3, 100_000, 30, 3600, price, reward);
        token.approve(address(game), reward);
        game.fundRewards(reward);
        game.startRound();
    }

    function _actor(uint256 index) private pure returns (address) {
        return address(uint160(0xD000 + index));
    }

    function _tickets(uint32 mask) private pure returns (uint256 count) {
        // Fixed-length enumeration is independent of the implementation's bit-clearing loop.
        for (uint256 i; i < 25; ++i) {
            if ((mask & (uint256(1) << i)) != 0) ++count;
        }
    }

    function testFuzz_eachPlayerReceivesOnlyTheirEntitlement(
        uint128 priceSeed,
        uint128 rewardSeed,
        uint32[5] memory masks,
        uint256 word,
        uint256 orderSeed
    ) public {
        uint128 price = uint128(bound(priceSeed, 1, type(uint128).max));
        uint128 reward = uint128(bound(rewardSeed, 1, 1e27));
        _exerciseDistribution(price, reward, masks, word, orderSeed);
    }

    function test_oneWeiPriceAndRewardStillLetEveryWinnerClaim() public {
        _exerciseDistribution(1, 1, [uint32(3), 1, 1, 1, 1], 0, 37);
    }

    function test_fullSupplyRewardMaximumPriceAndAllTiles() public {
        _exerciseDistribution(type(uint128).max, uint128(1e27), [ALL, ALL, ALL, ALL, ALL], type(uint256).max, 0);
    }

    function test_emptyWinningTileReturnsEvenMaximumPriceEntries() public {
        _exerciseDistribution(type(uint128).max, 1, [uint32(1), 1, 1, 1, 1], 24, 1);
    }

    function _exerciseDistribution(
        uint128 price,
        uint128 reward,
        uint32[5] memory masks,
        uint256 word,
        uint256 orderSeed
    ) private {
        GridMining game = _newGame(price, reward);
        Distribution memory d;
        d.price = price;
        d.reward = reward;
        d.tile = word % 25;
        for (uint256 i; i < 5; ++i) {
            masks[i] = uint32(bound(masks[i], 1, ALL));
            uint256 payment = _tickets(masks[i]) * uint256(price);
            d.pot += payment;
            if ((masks[i] & (uint256(1) << d.tile)) != 0) ++d.winners;
            vm.deal(_actor(i), payment);
            vm.prank(_actor(i));
            game.enter{value: payment}(1, masks[i]);
        }
        for (uint8 tile; tile < 25; ++tile) {
            uint256 buyers;
            for (uint256 i; i < 5; ++i) {
                if ((masks[i] & (uint32(1) << tile)) != 0) ++buyers;
            }
            assertEq(game.tileEntries(1, tile), buyers);
        }
        vm.warp(game.getRound(1).closesAt);
        game.closeRound(1);
        vrf.fulfill(game.getRound(1).requestId, word);
        game.settleRound(1);
        assertEq(
            uint256(game.getRound(1).state),
            uint256(d.winners == 0 ? GridMining.State.Refundable : GridMining.State.Settled)
        );
        assertEq(game.getRound(1).winningTile, d.tile);
        assertEq(game.getRound(1).winners, d.winners);
        assertEq(game.getRound(1).pot, d.pot);
        _claimInOrder(game, d, masks, orderSeed);
    }

    function _claimInOrder(GridMining game, Distribution memory d, uint32[5] memory masks, uint256 orderSeed) private {
        // Fisher-Yates exercises all claim permutations, rather than only rotations.
        uint256[5] memory order = [uint256(0), 1, 2, 3, 4];
        for (uint256 i = 5; i > 1; --i) {
            uint256 j = orderSeed % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
            orderSeed /= i;
        }
        for (uint256 k; k < 5; ++k) {
            uint256 i = order[k];
            uint256 expectedNative;
            uint256 expectedGold;
            if (d.winners == 0) {
                expectedNative = _tickets(masks[i]) * d.price;
            } else if ((masks[i] & (uint256(1) << d.tile)) != 0) {
                ++d.claimedWinners;
                expectedNative = d.pot / d.winners;
                expectedGold = d.reward / d.winners;
                if (d.claimedWinners == d.winners) {
                    expectedNative += d.pot % d.winners;
                    expectedGold += d.reward % d.winners;
                }
            }
            (uint256 quotedNative, uint256 quotedGold) = game.claimable(1, _actor(i));
            assertEq(quotedNative, expectedNative);
            assertEq(quotedGold, expectedGold);
            vm.prank(_actor(i));
            if (expectedNative == 0) {
                vm.expectRevert(GridMining.NothingToClaim.selector);
                game.claim(1, payable(_actor(i)));
            } else {
                game.claim(1, payable(_actor(i)));
                assertTrue(game.claimed(1, _actor(i)));
                vm.prank(_actor(i));
                vm.expectRevert(GridMining.NothingToClaim.selector);
                game.claim(1, payable(_actor(i)));
            }
            assertEq(_actor(i).balance, expectedNative);
            assertEq(token.balanceOf(_actor(i)), expectedGold);
            d.paidNative += expectedNative;
            d.paidGold += expectedGold;
            assertEq(game.nativeLiability(), d.pot - d.paidNative);
            assertEq(game.reservedRewards(), d.winners == 0 ? 0 : d.reward - d.paidGold);
        }
        assertEq(d.paidNative, d.pot);
        assertEq(d.paidGold, d.winners == 0 ? 0 : d.reward);
        assertEq(game.getRound(1).remainingNative, 0);
        assertEq(game.getRound(1).remainingGold, 0);
        assertEq(game.getRound(1).claimedWinners, d.winners);
        assertEq(address(game).balance, 0);
        assertEq(token.balanceOf(address(game)), d.winners == 0 ? d.reward : 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_overlappingPurchaseRollsBackNewTilesAndPayment(uint8 oldTileSeed, uint8 newTileSeed) public {
        GridMining game = _newGame(7, 11);
        uint8 oldTile = oldTileSeed % 25;
        uint8 newTile = uint8((uint256(oldTile) + 1 + newTileSeed % 24) % 25);
        uint32 existing = uint32(1) << oldTile;
        uint32 additional = uint32(1) << newTile;
        vm.deal(_actor(0), 21);
        vm.prank(_actor(0));
        game.enter{value: 7}(1, existing);
        bytes32 beforeRound = keccak256(abi.encode(game.getRound(1)));
        vm.prank(_actor(0));
        vm.expectRevert(GridMining.DuplicateTile.selector);
        game.enter{value: 14}(1, existing | additional);
        assertEq(keccak256(abi.encode(game.getRound(1))), beforeRound);
        assertEq(game.selections(1, _actor(0)), existing);
        assertEq(game.tileEntries(1, newTile), 0);
        assertEq(game.nativeLiability(), 7);
        assertEq(_actor(0).balance, 14);
        // The fresh tile in a rejected batch must remain available.
        vm.prank(_actor(0));
        game.enter{value: 7}(1, additional);
        assertEq(game.selections(1, _actor(0)), existing | additional);
        assertEq(game.getRound(1).entries, 2);
    }

    function test_failedFundingRestoresSpentAllowanceAndReserves() public {
        GridMining game = _newGame(7, 11);
        vm.prank(_actor(0));
        token.approve(address(game), 1);
        vm.prank(_actor(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _actor(0), 0, 1));
        game.fundRewards(1);
        assertEq(token.allowance(_actor(0), address(game)), 1);
        assertEq(game.availableRewards(), 0);
        assertEq(game.reservedRewards(), 11);
        assertEq(token.balanceOf(address(game)), 11);
    }

    function test_lastMomentRequestGetsFullWindowAndTimelyResultCannotExpire() public {
        GridMining game = _newGame(1, 1);
        vm.deal(_actor(0), 1);
        vm.prank(_actor(0));
        game.enter{value: 1}(1, 1);
        uint256 oldDeadline = game.getRound(1).deadline;
        vm.warp(oldDeadline - 1);
        game.closeRound(1);
        assertEq(game.getRound(1).deadline, oldDeadline - 1 + 3600);
        vm.warp(oldDeadline);
        vm.expectRevert(GridMining.TooEarly.selector);
        game.expireRound(1);
        vm.warp(game.getRound(1).deadline - 1);
        vrf.fulfill(game.getRound(1).requestId, 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(GridMining.WrongState.selector);
        game.expireRound(1);
        game.settleRound(1);
        vm.prank(_actor(0));
        game.claim(1, payable(_actor(0)));
        assertEq(_actor(0).balance, 1);
        assertEq(token.balanceOf(_actor(0)), 1);
    }

    function test_constructorAcceptsInclusiveUpperBoundsWithoutMovingTokens() public {
        GridMining game = new GridMining(
            address(token),
            address(vrf),
            bytes32(type(uint256).max),
            type(uint256).max,
            200,
            2_500_000,
            1 days,
            7 days,
            type(uint128).max,
            type(uint128).max
        );
        assertEq(game.requestConfirmations(), 200);
        assertEq(game.callbackGasLimit(), 2_500_000);
        assertEq(game.roundDuration(), 1 days);
        assertEq(game.oracleTimeout(), 7 days);
        assertEq(game.entryPrice(), type(uint128).max);
        assertEq(game.rewardPerRound(), type(uint128).max);
        assertEq(game.subscriptionId(), type(uint256).max);
        assertEq(game.keyHash(), bytes32(type(uint256).max));
        assertEq(token.balanceOf(address(this)), 1e27);
        vm.expectRevert(GridMining.InsufficientRewards.selector);
        game.startRound();
    }
}
