// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVRFCoordinator} from "./interfaces/IVRFCoordinator.sol";

/// @notice A 5x5 native-currency grid game with prefunded Gold prizes and asynchronous VRF draws.
/// @dev No owner, fee, upgrade, sweep or mint path. All configuration is immutable.
contract GridMining is ReentrancyGuard {
    uint8 public constant TILE_COUNT = 25;
    uint32 public constant ALL_TILES = (uint32(1) << TILE_COUNT) - 1;
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    enum State {
        None,
        Open,
        Requested,
        Ready,
        Settled,
        Refundable
    }

    enum RefundReason {
        EmptyRound,
        EmptyTile,
        Timeout
    }

    struct Round {
        State state;
        uint8 winningTile;
        uint256 closesAt;
        uint256 deadline;
        uint256 requestId;
        uint256 randomWord;
        uint256 entries;
        uint256 pot;
        uint256 winners;
        uint256 claimedWinners;
        uint256 remainingNative;
        uint256 remainingGold;
    }

    IERC20 public immutable gold;
    IVRFCoordinator public immutable coordinator;
    bytes32 public immutable keyHash;
    uint256 public immutable subscriptionId;
    uint16 public immutable requestConfirmations;
    uint32 public immutable callbackGasLimit;
    uint32 public immutable roundDuration;
    uint32 public immutable oracleTimeout;
    uint128 public immutable entryPrice;
    uint128 public immutable rewardPerRound;

    uint256 public currentRound;
    uint256 public availableRewards;
    uint256 public reservedRewards;
    uint256 public nativeLiability;

    mapping(uint256 roundId => Round) private _rounds;
    mapping(uint256 requestId => uint256 roundId) public requestRound;
    mapping(uint256 roundId => mapping(address player => uint32 tiles)) public selections;
    mapping(uint256 roundId => mapping(uint8 tile => uint256 count)) public tileEntries;
    mapping(uint256 roundId => mapping(address player => bool)) public claimed;

    error InvalidConfiguration();
    error InvalidAmount();
    error WrongState();
    error TooEarly();
    error DeadlinePassed();
    error InvalidTiles();
    error DuplicateTile();
    error IncorrectPayment();
    error InsufficientRewards();
    error UnauthorizedCoordinator();
    error InvalidRequestId();
    error NothingToClaim();
    error InvalidRecipient();
    error TransferFailed();

    event RewardsFunded(address indexed sponsor, uint256 amount);
    event RoundOpened(uint256 indexed roundId, uint256 closesAt, uint256 requestDeadline, uint256 goldReward);
    event Entered(uint256 indexed roundId, address indexed player, uint32 tiles, uint256 paid);
    event RandomnessRequested(uint256 indexed roundId, uint256 indexed requestId, uint256 fulfillmentDeadline);
    event RandomnessReceived(uint256 indexed roundId, uint256 indexed requestId, uint256 randomWord);
    event CallbackIgnored(uint256 indexed requestId);
    event RoundSettled(uint256 indexed roundId, uint8 winningTile, uint256 winners, uint256 pot, uint256 goldReward);
    event RoundRefundable(uint256 indexed roundId, RefundReason reason);
    event Claimed(
        uint256 indexed roundId,
        address indexed player,
        address indexed recipient,
        uint256 nativeAmount,
        uint256 goldAmount
    );

    /// @param gold_ Must be this project's LaunchToken; arbitrary/rebasing tokens are unsupported.
    /// @param coordinator_ Chainlink VRF v2.5 coordinator, verified externally on the selected chain.
    /// @dev The launch's isolated constructor check has no external-chain code. Only the token,
    /// deployed earlier by the factory, is required to have local code during construction.
    /// @param subscriptionId_ Existing externally funded LINK subscription; register this consumer externally.
    /// @param roundDuration_ Entry window in seconds, between 30 seconds and one day.
    /// @param oracleTimeout_ Each request/fulfillment window, between one hour and seven days.
    constructor(
        address gold_,
        address coordinator_,
        bytes32 keyHash_,
        uint256 subscriptionId_,
        uint16 requestConfirmations_,
        uint32 callbackGasLimit_,
        uint32 roundDuration_,
        uint32 oracleTimeout_,
        uint128 entryPrice_,
        uint128 rewardPerRound_
    ) {
        if (
            gold_.code.length == 0 || coordinator_ == address(0) || gold_ == coordinator_ || keyHash_ == bytes32(0)
                || subscriptionId_ == 0 || requestConfirmations_ < 3 || requestConfirmations_ > 200
                || callbackGasLimit_ < 100_000 || callbackGasLimit_ > 2_500_000 || roundDuration_ < 30
                || roundDuration_ > 1 days || oracleTimeout_ < 1 hours || oracleTimeout_ > 7 days || entryPrice_ == 0
                || rewardPerRound_ == 0
        ) revert InvalidConfiguration();
        gold = IERC20(gold_);
        coordinator = IVRFCoordinator(coordinator_);
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        requestConfirmations = requestConfirmations_;
        callbackGasLimit = callbackGasLimit_;
        roundDuration = roundDuration_;
        oracleTimeout = oracleTimeout_;
        entryPrice = entryPrice_;
        rewardPerRound = rewardPerRound_;
    }

    /// @notice Irrevocably donate Gold to future round rewards, after approving this contract.
    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = gold.balanceOf(address(this));
        if (!gold.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (gold.balanceOf(address(this)) - beforeBalance != amount) revert TransferFailed();
        availableRewards += amount;
        emit RewardsFunded(msg.sender, amount);
    }

    /// @notice Anyone may open the next round once the preceding round has a final outcome.
    function startRound() external nonReentrant returns (uint256 roundId) {
        State previous = _rounds[currentRound].state;
        if (currentRound != 0 && previous != State.Settled && previous != State.Refundable) revert WrongState();
        if (availableRewards < rewardPerRound) revert InsufficientRewards();
        availableRewards -= rewardPerRound;
        reservedRewards += rewardPerRound;
        roundId = ++currentRound;
        Round storage r = _rounds[roundId];
        r.state = State.Open;
        r.closesAt = block.timestamp + roundDuration;
        r.deadline = r.closesAt + oracleTimeout;
        r.remainingGold = rewardPerRound;
        emit RoundOpened(roundId, r.closesAt, r.deadline, rewardPerRound);
    }

    /// @notice Buy one ticket on each selected tile. Bit i selects tile i (row-major, 0..24).
    /// @dev Repeated calls may add distinct tiles; selecting an already purchased tile reverts atomically.
    /// The explicit roundId prevents a delayed transaction from entering a subsequent round.
    function enter(uint256 roundId, uint32 tiles) external payable nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != State.Open) revert WrongState();
        if (block.timestamp >= r.closesAt) revert DeadlinePassed();
        if (tiles == 0 || tiles > ALL_TILES) revert InvalidTiles();
        if ((selections[roundId][msg.sender] & tiles) != 0) revert DuplicateTile();
        uint256 count = _countTiles(tiles);
        if (msg.value != count * entryPrice) revert IncorrectPayment();
        selections[roundId][msg.sender] |= tiles;
        r.entries += count;
        r.pot += msg.value;
        r.remainingNative += msg.value;
        nativeLiability += msg.value;
        for (uint8 tile; tile < TILE_COUNT; ++tile) {
            if ((tiles & (uint32(1) << tile)) != 0) ++tileEntries[roundId][tile];
        }
        emit Entered(roundId, msg.sender, tiles, msg.value);
    }

    /// @notice Close entries and request one word. An empty round returns its Gold reserve immediately.
    /// @dev A reverted coordinator call rolls the whole request back; no accepted request can be retried.
    function closeRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != State.Open) revert WrongState();
        if (block.timestamp < r.closesAt) revert TooEarly();
        if (block.timestamp >= r.deadline) revert DeadlinePassed();
        if (r.entries == 0) {
            _makeRefundable(roundId, r, RefundReason.EmptyRound);
            return;
        }
        r.state = State.Requested;
        r.deadline = block.timestamp + oracleTimeout;
        uint256 requestId = coordinator.requestRandomWords(
            IVRFCoordinator.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false)
            })
        );
        if (requestId == 0 || requestRound[requestId] != 0) revert InvalidRequestId();
        r.requestId = requestId;
        requestRound[requestId] = roundId;
        emit RandomnessRequested(roundId, requestId, r.deadline);
    }

    /// @notice Chainlink callback: authenticate, bind the request, and store the result without external calls.
    /// @dev Stale, duplicate, malformed and expired callbacks are ignored. Expiry uses a strict timestamp
    /// boundary so a late callback cannot race a refund. The coordinator's proof verifier is trusted.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external {
        if (msg.sender != address(coordinator)) revert UnauthorizedCoordinator();
        uint256 roundId = requestRound[requestId];
        Round storage r = _rounds[roundId];
        if (roundId == 0 || r.state != State.Requested || block.timestamp >= r.deadline || words.length != 1) {
            emit CallbackIgnored(requestId);
            return;
        }
        r.randomWord = words[0];
        r.state = State.Ready;
        emit RandomnessReceived(roundId, requestId, words[0]);
    }

    /// @notice Permissionless constant-cost settlement, independent of any recipient's behavior.
    function settleRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != State.Ready) revert WrongState();
        // Reduction bias is less than 25 / 2^256. Neither caller nor block data supplies entropy.
        r.winningTile = uint8(r.randomWord % TILE_COUNT);
        r.winners = tileEntries[roundId][r.winningTile];
        if (r.winners == 0) {
            _makeRefundable(roundId, r, RefundReason.EmptyTile);
        } else {
            r.state = State.Settled;
            emit RoundSettled(roundId, r.winningTile, r.winners, r.pot, rewardPerRound);
        }
    }

    /// @notice Refund a round whose request or fulfillment deadline was missed.
    /// @dev A timely stored result can never expire. There is no reroll of a round's accepted request.
    function expireRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != State.Open && r.state != State.Requested) revert WrongState();
        if (block.timestamp < r.deadline) revert TooEarly();
        _makeRefundable(roundId, r, RefundReason.Timeout);
    }

    /// @notice Claim your prize or full refund to a payable recipient of your choice.
    /// @dev The last winning claimant receives division dust. Failed delivery leaves the claim intact.
    function claim(uint256 roundId, address payable recipient) external nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        (uint256 nativeAmount, uint256 goldAmount) = claimable(roundId, msg.sender);
        if (nativeAmount == 0 && goldAmount == 0) revert NothingToClaim();
        Round storage r = _rounds[roundId];
        claimed[roundId][msg.sender] = true;
        if (r.state == State.Settled) ++r.claimedWinners;
        r.remainingNative -= nativeAmount;
        r.remainingGold -= goldAmount;
        nativeLiability -= nativeAmount;
        reservedRewards -= goldAmount;
        emit Claimed(roundId, msg.sender, recipient, nativeAmount, goldAmount);
        if (goldAmount != 0 && !gold.transfer(recipient, goldAmount)) revert TransferFailed();
        if (nativeAmount != 0) {
            (bool ok,) = recipient.call{value: nativeAmount}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Current entitlement; the last winning claim includes all remaining division dust.
    function claimable(uint256 roundId, address player) public view returns (uint256 nativeAmount, uint256 goldAmount) {
        if (claimed[roundId][player]) return (0, 0);
        Round storage r = _rounds[roundId];
        uint32 tiles = selections[roundId][player];
        if (r.state == State.Refundable) return (_countTiles(tiles) * entryPrice, 0);
        if (r.state != State.Settled || (tiles & (uint32(1) << r.winningTile)) == 0) return (0, 0);
        if (r.claimedWinners + 1 == r.winners) return (r.remainingNative, r.remainingGold);
        return (r.pot / r.winners, uint256(rewardPerRound) / r.winners);
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function _makeRefundable(uint256 roundId, Round storage r, RefundReason reason) private {
        r.state = State.Refundable;
        availableRewards += r.remainingGold;
        reservedRewards -= r.remainingGold;
        r.remainingGold = 0;
        emit RoundRefundable(roundId, reason);
    }

    function _countTiles(uint32 tiles) private pure returns (uint256 count) {
        while (tiles != 0) {
            tiles &= tiles - 1;
            ++count;
        }
    }
}
