// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {GridMining} from "../../src/GridMining.sol";
import {MockVRFCoordinator} from "./MockVRFCoordinator.sol";

abstract contract GridFixture is Test {
    LaunchToken internal token;
    MockVRFCoordinator internal vrf;
    GridMining internal game;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint128 internal constant PRICE = 0.001 ether;
    uint128 internal constant REWARD = 100 ether;
    uint256 internal constant FUND = 1_000 ether;
    uint32 internal constant DURATION = 90;
    uint32 internal constant TIMEOUT = 1 days;
    bytes32 internal constant KEY = bytes32(uint256(42));

    function setUp() public virtual {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vrf = new MockVRFCoordinator();
        game = new GridMining(address(token), address(vrf), KEY, 1, 3, 100_000, DURATION, TIMEOUT, PRICE, REWARD);
        token.approve(address(game), FUND);
        game.fundRewards(FUND);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);
    }

    function _enter(uint256 id, address player, uint32 tiles) internal {
        vm.prank(player);
        game.enter{value: _count(tiles) * PRICE}(id, tiles);
    }

    function _close(uint256 id) internal returns (uint256) {
        vm.warp(game.getRound(id).closesAt);
        game.closeRound(id);
        return game.getRound(id).requestId;
    }

    function _settle(uint256 id, uint256 word) internal {
        uint256 requestId = _close(id);
        vrf.fulfill(requestId, word);
        game.settleRound(id);
    }

    function _claim(uint256 id, address player) internal {
        vm.prank(player);
        game.claim(id, payable(player));
    }

    function _count(uint32 mask) internal pure returns (uint256 count) {
        while (mask != 0) {
            mask &= mask - 1;
            ++count;
        }
    }

    function _assertAccounting() internal view {
        assertEq(address(game).balance, game.nativeLiability());
        assertEq(token.balanceOf(address(game)), game.availableRewards() + game.reservedRewards());
        assertEq(token.totalSupply(), 1e27);
    }
}
