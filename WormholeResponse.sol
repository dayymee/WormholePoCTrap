// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Response {
    address public owner;

    struct BridgeAlert {
        address bridge;
        uint8 reason;
        uint256 lastSeenSequence;
        uint256 currentSequence;
        uint256 lastGuardianIndex;
        uint256 currentGuardianIndex;
        uint256 backlog;
        uint256 lastTs;
        bytes32 vaaHash;
        bool conflict;
        uint256 timestamp;
        address reporter;
    }

    BridgeAlert public lastAlert;

    event BridgeAlertRecorded(
        address bridge,
        uint8 reason,
        uint256 lastSeenSequence,
        uint256 currentSequence,
        uint256 lastGuardianIndex,
        uint256 currentGuardianIndex,
        uint256 backlog,
        uint256 lastTs,
        bytes32 vaaHash,
        bool conflict,
        uint256 timestamp,
        address reporter
    );

    function init(address _owner) external {
        require(owner == address(0), "already init");
        require(_owner != address(0), "owner zero");
        owner = _owner;
    }

    // Updated to match WormholePoCTrap.collect() encoding
    function respondWithBridgeAlert(
        address bridge,
        uint8 reason,
        uint256 lastSeenSequence,
        uint256 currentSequence,
        uint256 lastGuardianIndex,
        uint256 currentGuardianIndex,
        uint256 backlog,
        uint256 lastTs,
        bytes32 vaaHash,
        bool conflict
    ) external {
        lastAlert = BridgeAlert({
            bridge: bridge,
            reason: reason,
            lastSeenSequence: lastSeenSequence,
            currentSequence: currentSequence,
            lastGuardianIndex: lastGuardianIndex,
            currentGuardianIndex: currentGuardianIndex,
            backlog: backlog,
            lastTs: lastTs,
            vaaHash: vaaHash,
            conflict: conflict,
            timestamp: block.timestamp,
            reporter: msg.sender
        });

        emit BridgeAlertRecorded(
            bridge,
            reason,
            lastSeenSequence,
            currentSequence,
            lastGuardianIndex,
            currentGuardianIndex,
            backlog,
            lastTs,
            vaaHash,
            conflict,
            block.timestamp,
            msg.sender
        );
    }

    function getLastAlert() external view returns (BridgeAlert memory) {
        return lastAlert;
    }
}
