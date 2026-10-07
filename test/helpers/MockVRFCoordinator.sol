// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinator} from "../../src/interfaces/IVRFCoordinator.sol";

interface IRandomWordsConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external;
}

/// @dev Local behavior mock only. No proof verification and never a production deployment dependency.
contract MockVRFCoordinator is IVRFCoordinator {
    uint256 public lastRequestId;
    mapping(uint256 => address) public consumers;
    bool public failRequests;
    bool public overrideId;
    uint256 public forcedId;
    RandomWordsRequest private _lastRequest;

    function configure(bool fail, bool overrideId_, uint256 forcedId_) external {
        failRequests = fail;
        overrideId = overrideId_;
        forcedId = forcedId_;
    }

    function requestRandomWords(RandomWordsRequest calldata request) external returns (uint256 id) {
        require(!failRequests, "VRF unavailable");
        id = overrideId ? forcedId : ++lastRequestId;
        consumers[id] = msg.sender;
        _lastRequest = request;
    }

    function lastRequest() external view returns (RandomWordsRequest memory) {
        return _lastRequest;
    }

    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IRandomWordsConsumer(consumers[id]).rawFulfillRandomWords(id, words);
    }

    function deliver(address consumer, uint256 id, uint256[] calldata words) external {
        IRandomWordsConsumer(consumer).rawFulfillRandomWords(id, words);
    }

    function fulfillWithGas(uint256 id, uint256 word, uint256 gasLimit) external returns (bool) {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (bool ok,) =
            consumers[id].call{gas: gasLimit}(abi.encodeCall(IRandomWordsConsumer.rawFulfillRandomWords, (id, words)));
        return ok;
    }
}
