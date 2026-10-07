// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GridFixture} from "./helpers/GridFixture.sol";
import {GridMining} from "../src/GridMining.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RejectNative {
    receive() external payable {
        revert("reject ETH");
    }
}

contract ReentrantPlayer {
    GridMining private immutable game;
    uint256 private id;
    bool public reenteredClaim;
    bool public reenteredStart;

    constructor(GridMining game_) {
        game = game_;
    }

    function enter(uint256 id_, uint32 tiles) external payable {
        id = id_;
        game.enter{value: msg.value}(id_, tiles);
    }

    function claim() external {
        game.claim(id, payable(address(this)));
    }

    receive() external payable {
        (reenteredClaim,) = address(game).call(abi.encodeCall(GridMining.claim, (id, payable(address(this)))));
        (reenteredStart,) = address(game).call(abi.encodeCall(GridMining.startRound, ()));
    }
}

contract SwitchableToken is ERC20 {
    bool public fail;
    bool public fee;

    constructor() ERC20("Test", "Test") {
        _mint(msg.sender, 1e27);
    }

    function configure(bool fail_, bool fee_) external {
        fail = fail_;
        fee = fee_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        return super.transferFrom(from, to, fee ? amount - 1 : amount);
    }
}

contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract GridMiningSecurityTest is GridFixture {
    function test_failedNativePayoutRollsBackGoldAndCanBeRedirected() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 0);
        RejectNative reject = new RejectNative();
        vm.prank(ALICE);
        vm.expectRevert(GridMining.TransferFailed.selector);
        game.claim(id, payable(address(reject)));
        assertFalse(game.claimed(id, ALICE));
        assertEq(game.getRound(id).claimedWinners, 0);
        assertEq(token.balanceOf(address(reject)), 0);
        assertEq(game.reservedRewards(), REWARD);
        assertEq(game.nativeLiability(), PRICE);
        assertEq(game.startRound(), 2); // Rejected payout cannot hold the next round hostage.
        _claim(id, ALICE);
        _assertAccounting();
    }

    function test_failedRefundLeavesItClaimable() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 24);
        RejectNative reject = new RejectNative();
        vm.prank(ALICE);
        vm.expectRevert(GridMining.TransferFailed.selector);
        game.claim(id, payable(address(reject)));
        assertFalse(game.claimed(id, ALICE));
        _claim(id, ALICE);
        assertEq(ALICE.balance, 100 ether);
        _assertAccounting();
    }

    function test_reentrancyCannotDoubleClaimOrOpenRoundDuringPayout() public {
        ReentrantPlayer attacker = new ReentrantPlayer(game);
        uint256 id = game.startRound();
        vm.deal(address(this), PRICE);
        attacker.enter{value: PRICE}(id, 1);
        _settle(id, 0);
        attacker.claim();
        assertFalse(attacker.reenteredClaim());
        assertFalse(attacker.reenteredStart());
        assertEq(game.currentRound(), id);
        assertEq(address(attacker).balance, PRICE);
        assertEq(token.balanceOf(address(attacker)), REWARD);
        _assertAccounting();
    }

    function test_refundReentrancyCannotDoubleClaim() public {
        ReentrantPlayer attacker = new ReentrantPlayer(game);
        uint256 id = game.startRound();
        vm.deal(address(this), PRICE);
        attacker.enter{value: PRICE}(id, 1);
        _settle(id, 24);
        attacker.claim();
        assertFalse(attacker.reenteredClaim());
        assertFalse(attacker.reenteredStart());
        assertEq(address(attacker).balance, PRICE);
        _assertAccounting();
    }

    function test_failedTokenFundingAndFeeTokenAreRejected() public {
        SwitchableToken bad = new SwitchableToken();
        GridMining other =
            new GridMining(address(bad), address(vrf), KEY, 1, 3, 100_000, DURATION, TIMEOUT, PRICE, REWARD);
        bad.approve(address(other), REWARD);
        bad.configure(true, false);
        vm.expectRevert(GridMining.TransferFailed.selector);
        other.fundRewards(REWARD);
        bad.configure(false, true);
        vm.expectRevert(GridMining.TransferFailed.selector);
        other.fundRewards(REWARD);
        assertEq(other.availableRewards(), 0);
        assertEq(bad.balanceOf(address(other)), 0);
    }

    function test_failedGoldPayoutIsAtomic() public {
        SwitchableToken bad = new SwitchableToken();
        GridMining other =
            new GridMining(address(bad), address(vrf), KEY, 1, 3, 100_000, DURATION, TIMEOUT, PRICE, REWARD);
        bad.approve(address(other), REWARD);
        other.fundRewards(REWARD);
        other.startRound();
        vm.prank(ALICE);
        other.enter{value: PRICE}(1, 1);
        vm.warp(other.getRound(1).closesAt);
        other.closeRound(1);
        vrf.fulfill(other.getRound(1).requestId, 0);
        other.settleRound(1);
        bad.configure(true, false);
        vm.prank(ALICE);
        vm.expectRevert(GridMining.TransferFailed.selector);
        other.claim(1, payable(ALICE));
        assertFalse(other.claimed(1, ALICE));
        assertEq(other.nativeLiability(), PRICE);
        assertEq(other.reservedRewards(), REWARD);
        bad.configure(false, false);
        vm.prank(ALICE);
        other.claim(1, payable(ALICE));
        assertEq(other.nativeLiability(), 0);
        assertEq(other.reservedRewards(), 0);
    }

    function test_donationsCannotChangeEntitlements() public {
        uint256 id = game.startRound();
        _enter(id, ALICE, 1);
        _settle(id, 0);
        token.transfer(address(game), 7 ether); // Untracked direct donation, outside fundRewards.
        vm.deal(address(game), address(game).balance + 5 ether); // Models forcibly delivered ETH.
        _claim(id, ALICE);
        assertEq(ALICE.balance, 100 ether);
        assertEq(token.balanceOf(ALICE), REWARD);
        assertEq(address(game).balance, 5 ether);
        assertEq(game.nativeLiability(), 0);
        assertEq(token.balanceOf(address(game)), game.availableRewards() + 7 ether);
    }

    function test_factoryConstructionPreservesFullSupplyAndHasNoOwnerAssumption() public {
        FactoryProbe factory = new FactoryProbe();
        LaunchToken launched = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        bytes memory code = abi.encodePacked(
            type(GridMining).creationCode,
            abi.encode(
                address(launched),
                address(vrf),
                KEY,
                uint256(1),
                uint16(3),
                uint32(100_000),
                DURATION,
                TIMEOUT,
                PRICE,
                REWARD
            )
        );
        GridMining deployed = GridMining(factory.deploy(code, bytes32(uint256(2))));
        assertEq(launched.totalSupply(), 1e27);
        assertEq(launched.balanceOf(address(factory)), 1e27);
        assertEq(launched.balanceOf(address(deployed)), 0);
        assertEq(deployed.availableRewards(), 0);
        assertEq(address(deployed.gold()), address(launched));
        _checkRuntime(address(launched));
        _checkRuntime(address(deployed));
    }

    function test_isolatedConstructorDoesNotRequireExternalChainCode() public {
        address externalCoordinator = address(0xC001);
        assertEq(externalCoordinator.code.length, 0);
        GridMining isolated =
            new GridMining(address(token), externalCoordinator, KEY, 1, 3, 100_000, DURATION, TIMEOUT, PRICE, REWARD);
        assertEq(address(isolated.coordinator()), externalCoordinator);
        assertEq(token.balanceOf(address(this)), 1e27 - FUND);
        assertEq(token.balanceOf(address(isolated)), 0);
    }

    function testFuzz_rejectsInvalidConstructorConfiguration(uint8 choice) public {
        address tokenAddress = address(token);
        address coordinatorAddress = address(vrf);
        bytes32 key = KEY;
        uint256 sub = 1;
        uint16 confirmations = 3;
        uint32 gasLimit = 100_000;
        uint32 duration = DURATION;
        uint32 timeout = TIMEOUT;
        uint128 price = PRICE;
        uint128 reward = REWARD;
        choice %= 16;
        if (choice == 0) tokenAddress = address(0);
        else if (choice == 1) coordinatorAddress = address(0);
        else if (choice == 2) coordinatorAddress = tokenAddress;
        else if (choice == 3) key = 0;
        else if (choice == 4) sub = 0;
        else if (choice == 5) confirmations = 2;
        else if (choice == 6) confirmations = 201;
        else if (choice == 7) gasLimit = 99_999;
        else if (choice == 8) gasLimit = 2_500_001;
        else if (choice == 9) duration = 29;
        else if (choice == 10) duration = 1 days + 1;
        else if (choice == 11) timeout = 1 hours - 1;
        else if (choice == 12) timeout = 7 days + 1;
        else if (choice == 13) price = 0;
        else if (choice == 14) reward = 0;
        else tokenAddress = BOB;
        vm.expectRevert(GridMining.InvalidConfiguration.selector);
        new GridMining(
            tokenAddress, coordinatorAddress, key, sub, confirmations, gasLimit, duration, timeout, price, reward
        );
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
