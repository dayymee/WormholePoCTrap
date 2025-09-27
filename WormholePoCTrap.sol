// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/*
  WormholePoCTrap.sol
  - No constructor. Use init(...) to initialize.
  - Implements ITrap (so Drosera can call shouldRespond(...) and collect(...))
  - Implements checks:
     1) stale finality (lastProcessedTimestamp older than maxUnprocessedSeconds)
     2) unexpected guardian set change vs baseline (lastGuardianIndex)
     3) backlog threshold (unprocessed message count)
     4) conflicting VAAs: operators submit observed VAA hashes with submitVAAHash(); if two different hashes seen for same sequence => conflict
  - Minimal, defensive staticcall probing for common Wormhole-like getters so it works with slightly different test deployments or mocks on Hoodi.
*/

interface ITrapInternal {
    function shouldRespond(bytes calldata data) external view returns (bool);
    function collect(bytes calldata data) external view returns (bytes memory);
}

contract Trap is ITrap {
    // Basic storage
    address public owner;
    address public bridge;                // Wormhole core bridge address to monitor
    uint256 public maxUnprocessedSeconds; // stale finality threshold (seconds)
    uint256 public backlogThreshold;      // unprocessed messages count threshold
    uint256 public lastSeenSequence;      // baseline sequence
    uint256 public lastGuardianIndex;     // baseline guardian index
    bool public enabled;

    // VAA hash tracking (off-chain VAAs submitted by operator)
    // firstSeenHash[sequence] = the first submitted vaaHash for that sequence
    mapping(uint256 => bytes32) public firstSeenHash;
    // conflictRecorded[sequence] = true when two different hashes submitted for same sequence
    mapping(uint256 => bool) public conflictRecorded;

    event ConfigUpdated(address bridge, uint256 maxUnprocessedSeconds, uint256 backlogThreshold);
    event SampleUpdated(uint256 sequence, uint256 guardianIndex);
    event VAAHashSubmitted(uint256 indexed sequence, bytes32 vaaHash, address submitter, bool conflict);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // ---- no constructor ----
    function init(address _owner, address _bridge, uint256 _maxUnprocessedSeconds, uint256 _backlogThreshold) external {
        require(owner == address(0), "already initialized");
        require(_owner != address(0), "owner zero");
        owner = _owner;
        bridge = _bridge;
        maxUnprocessedSeconds = _maxUnprocessedSeconds;
        backlogThreshold = _backlogThreshold;
        enabled = true;

        // bootstrap baseline (best-effort)
        (uint256 seq, ) = _tryReadUint256Multiple(_sequenceSelectors());
        (uint256 gIdx, ) = _tryReadUint256Multiple(_guardianIndexSelectors());
        lastSeenSequence = seq;
        lastGuardianIndex = gIdx;

        emit ConfigUpdated(_bridge, _maxUnprocessedSeconds, _backlogThreshold);
        emit SampleUpdated(seq, gIdx);
    }

    function setConfig(address _bridge, uint256 _maxUnprocessedSeconds, uint256 _backlogThreshold) external onlyOwner {
        bridge = _bridge;
        maxUnprocessedSeconds = _maxUnprocessedSeconds;
        backlogThreshold = _backlogThreshold;
        emit ConfigUpdated(_bridge, _maxUnprocessedSeconds, _backlogThreshold);
    }

    function setEnabled(bool e) external onlyOwner { enabled = e; }

    // ---- selector helpers (tries multiple likely selectors) ----
    function _sequenceSelectors() internal pure returns (bytes4[4] memory sel) {
        sel[0] = bytes4(keccak256("getCurrentSequence()"));
        sel[1] = bytes4(keccak256("sequence()"));
        sel[2] = bytes4(keccak256("nextSequence()"));
        sel[3] = bytes4(keccak256("lastSequence()"));
    }

    function _guardianIndexSelectors() internal pure returns (bytes4[3] memory sel) {
        sel[0] = bytes4(keccak256("getCurrentGuardianSetIndex()"));
        sel[1] = bytes4(keccak256("guardianSetIndex()"));
        sel[2] = bytes4(keccak256("guardian_index()"));
    }

    function _lastProcessedTimestampSelectors() internal pure returns (bytes4[3] memory sel) {
        sel[0] = bytes4(keccak256("lastProcessedTimestamp()"));
        sel[1] = bytes4(keccak256("lastProcessedTime()"));
        sel[2] = bytes4(keccak256("timeLastProcessed()"));
    }

    function _unprocessedCountSelectors() internal pure returns (bytes4[3] memory sel) {
        sel[0] = bytes4(keccak256("unprocessedCount()"));
        sel[1] = bytes4(keccak256("pendingMessages()"));
        sel[2] = bytes4(keccak256("getUnprocessedMessageCount()"));
    }

    // ---- low-level readers to be tolerant to ABI differences ----
    function _tryReadUint256Multiple(bytes4[4] memory selectors) internal view returns (uint256 value, bool ok) {
        if (bridge == address(0)) return (0, false);
        for (uint i = 0; i < selectors.length; i++) {
            (bool success, bytes memory ret) = bridge.staticcall(abi.encodeWithSelector(selectors[i]));
            if (!success) continue;
            if (ret.length >= 32) {
                value = abi.decode(ret, (uint256));
                return (value, true);
            }
        }
        return (0, false);
    }

    function _tryReadUint256Multiple(bytes4[3] memory selectors) internal view returns (uint256 value, bool ok) {
        if (bridge == address(0)) return (0, false);
        for (uint i = 0; i < selectors.length; i++) {
            (bool success, bytes memory ret) = bridge.staticcall(abi.encodeWithSelector(selectors[i]));
            if (!success) continue;
            if (ret.length >= 32) {
                value = abi.decode(ret, (uint256));
                return (value, true);
            }
        }
        return (0, false);
    }

    function _tryReadTimestamp() internal view returns (uint256 ts, bool ok) {
        if (bridge == address(0)) return (0, false);
        bytes4[3] memory sels = _lastProcessedTimestampSelectors();
        for (uint i = 0; i < sels.length; i++) {
            (bool success, bytes memory ret) = bridge.staticcall(abi.encodeWithSelector(sels[i]));
            if (success && ret.length >= 32) {
                ts = abi.decode(ret, (uint256));
                return (ts, true);
            }
        }
        return (0, false);
    }

    function _tryUnprocessedCount() internal view returns (uint256 cnt, bool ok) {
        if (bridge == address(0)) return (0, false);
        bytes4[3] memory sels = _unprocessedCountSelectors();
        for (uint i = 0; i < sels.length; i++) {
            (bool success, bytes memory ret) = bridge.staticcall(abi.encodeWithSelector(sels[i]));
            if (success && ret.length >= 32) {
                cnt = abi.decode(ret, (uint256));
                return (cnt, true);
            }
        }
        return (0, false);
    }

    // ---- VAA hash submission (operators submit off-chain VAA hashes)
    // Only the contract owner (operator) can call this in PoC. Set owner to operator address.
    // First submission stores the hash. Second submission with a different hash flags a conflict.
    function submitVAAHash(uint256 sequence, bytes32 vaaHash) external onlyOwner {
        bytes32 existing = firstSeenHash[sequence];
        bool conflict = false;
        if (existing == bytes32(0)) {
            firstSeenHash[sequence] = vaaHash;
        } else {
            if (existing != vaaHash) {
                conflictRecorded[sequence] = true;
                conflict = true;
            }
        }
        emit VAAHashSubmitted(sequence, vaaHash, msg.sender, conflict);
    }

    // ---- ITrap: shouldRespond checks the four conditions ----
    // NOTE: the upstream ITrap interface expects `shouldRespond(bytes[] calldata)` and returns (bool, bytes memory)
    // At the interface-level `shouldRespond` is required to be pure in the drosera ITrap; for this PoC we return a simple placeholder.
    function shouldRespond(bytes[] calldata /*data*/) external pure override returns (bool, bytes memory) {
        // If you want on-chain logic to decide shouldRespond in future, the ITrap signature may need to be different
        // or Drosera will call collect() after a separate trigger. For now return false (no response) and empty payload.
        return (false, "");
    }

    // ---- ITrap: collect returns encoded diagnostic payload
    // payload layout:
    // abi.encode(
    //   bridge,
    //   lastSeenSequence,
    //   currentSequence,
    //   lastGuardianIndex,
    //   currentGuardianIndex,
    //   backlog,
    //   lastProcessedTs,
    //   reasonCode (uint8),
    //   vaaHash (bytes32 - firstSeen for currentSequence or zero),
    //   conflictFlag (bool)
    // )
    //
    // NOTE: reduced local variables to avoid "stack too deep".
    function collect() external view override returns (bytes memory) {
        uint8 reason = 0;

        // read values (each helper returns (value, ok) but we only keep the value to reduce stack usage)
        (uint256 curSeq, ) = _tryReadUint256Multiple(_sequenceSelectors());
        (uint256 curG, ) = _tryReadUint256Multiple(_guardianIndexSelectors());
        (uint256 backlog, ) = _tryUnprocessedCount();
        (uint256 lastTs, ) = _tryReadTimestamp();

        // determine reason priority: stale(1) > backlog(2) > guardian(3) > conflict(4)
        if (lastTs != 0 && block.timestamp > lastTs + maxUnprocessedSeconds) {
            reason = 1;
        } else if (backlog != 0 && backlog >= backlogThreshold) {
            reason = 2;
        } else if (lastGuardianIndex != 0 && curG != 0 && curG != lastGuardianIndex) {
            reason = 3;
        } else {
            // conflict check
            if (curSeq != 0) {
                if (conflictRecorded[curSeq]) reason = 4;
                else if (lastSeenSequence != 0 && conflictRecorded[lastSeenSequence]) reason = 4;
            }
        }

        // pick which sequence to report (prefer current if present)
        uint256 seqToReport = curSeq != 0 ? curSeq : lastSeenSequence;
        bytes32 vaaHash = bytes32(0);
        bool conflict = false;
        if (seqToReport != 0) {
            vaaHash = firstSeenHash[seqToReport];
            conflict = conflictRecorded[seqToReport];
        }

        return abi.encode(bridge, lastSeenSequence, curSeq, lastGuardianIndex, curG, backlog, lastTs, reason, vaaHash, conflict);
    }

    // ---- owner actions for baseline samples ----
    function refreshSample() external onlyOwner {
        (uint256 seq, bool gotSeq) = _tryReadUint256Multiple(_sequenceSelectors());
        (uint256 gIdx, bool gotG) = _tryReadUint256Multiple(_guardianIndexSelectors());
        if (gotSeq) lastSeenSequence = seq;
        if (gotG) lastGuardianIndex = gIdx;
        emit SampleUpdated(lastSeenSequence, lastGuardianIndex);
    }

    function setBaselineSequence(uint256 seq) external onlyOwner {
        lastSeenSequence = seq;
        emit SampleUpdated(lastSeenSequence, lastGuardianIndex);
    }
    function setBaselineGuardianIndex(uint256 idx) external onlyOwner {
        lastGuardianIndex = idx;
        emit SampleUpdated(lastSeenSequence, lastGuardianIndex);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
