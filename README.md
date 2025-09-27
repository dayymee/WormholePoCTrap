# WormholePoCTrap

A minimal Proof-of-Concept Drosera *trap* and matching *response* contract that monitor a Wormhole-like bridge for simple anomalies:

* stale finality (bridge's `lastProcessedTimestamp` older than a threshold)
* building message backlog (unprocessed count above a threshold)
* unexpected guardian set change (guardian set index deviates from baseline)
* conflicting VAAs (operator-submitted off-chain VAA hashes conflict for same sequence)

This PoC is intentionally defensive: the trap uses `staticcall` probing with multiple likely selectors so it will work with variations or mocks of a Wormhole-like bridge.

## Files

* `WormholePoCTrap.sol` — the main trap contract (no constructor; `init(...)` must be used).
* `WormholeResponse.sol` — a small response contract that records alerts (called by Drosera/operator after a trigger).
* `drosera.toml` — example Drosera configuration (response contract & function signature).
* `LICENSE` — MIT

---

## High-level behavior

### Trap (`WormholePoCTrap.sol`)

* Store owner/operator, monitored `bridge` address, thresholds and baselines.
* Operators can submit off-chain VAA hashes with `submitVAAHash(sequence, vaaHash)`; the trap flags a conflict if two different hashes are submitted for the same `sequence`.
* Implements tolerant readers (`_tryReadUint256Multiple`, `_tryReadTimestamp`, `_tryUnprocessedCount`) that try multiple probable selectors to handle ABI differences across deployments or mocks.
* `collect()` (view) constructs a diagnostic payload encoded as:

  ```
  abi.encode(
    bridge,                // address
    lastSeenSequence,      // uint256
    currentSequence,       // uint256
    lastGuardianIndex,     // uint256
    currentGuardianIndex,  // uint256
    backlog,               // uint256
    lastProcessedTs,       // uint256
    reasonCode,            // uint8 (1=stale,2=backlog,3=guardian change,4=conflict,0=none)
    vaaHash,               // bytes32 (first seen for chosen sequence)
    conflictFlag           // bool
  )
  ```
* Note: `shouldRespond(...)` in the included PoC matches the `ITrap` interface used by Drosera (the PoC currently contains a placeholder `shouldRespond` return to match the interface signature your Drosera deployment expects; Drosera typically uses `collect()` payloads for diagnostics).

### Response (`WormholeResponse.sol`)

* `respondWithBridgeAlert(...)` saves the alert into a `lastAlert` struct and emits an event.
* In the provided response contract we updated the signature to match the 10-field payload returned by `collect()` (see section below for exact function signature).
* The response contract is intentionally minimal and is easy to extend to call guardians/pause functions when an alert occurs.

---

## Deploy & Build (Foundry)

Assumes Foundry is installed.

1. Build

```bash
forge build
```

2. Deploy (example using `forge create` — adapt private key / rpc / addresses):

```bash
# Example: deploy trap
forge create src/WormholePoCTrap.sol:Trap --rpc-url $RPC_URL --private-key $DEPLOYER_KEY \
  --constructor-args

# Deploy response
forge create src/WormholeResponse.sol:Response --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
```

(Trap has no constructor — use `init(...)` after deployment.)

3. Initialize trap

```bash
# after trap deployment, call init
cast send <TRAP_ADDRESS> "init(address,address,uint256,uint256)" \
  <OWNER_ADDRESS> <BRIDGE_ADDRESS> <MAX_UNPROCESSED_SECONDS> <BACKLOG_THRESHOLD> \
  --private-key $OPERATOR_KEY
```

4. Initialize response

```bash
cast send <RESPONSE_ADDRESS> "init(address)" <OWNER_ADDRESS> --private-key $OPERATOR_KEY
```

5. Set baseline sample (optional)

```bash
cast send <TRAP_ADDRESS> "refreshSample()" --private-key $OPERATOR_KEY
# or set manually:
cast send <TRAP_ADDRESS> "setBaselineSequence(uint256)" <SEQ> --private-key $OPERATOR_KEY
cast send <TRAP_ADDRESS> "setBaselineGuardianIndex(uint256)" <INDEX> --private-key $OPERATOR_KEY
```

6. Submit VAA hashes (operator)

```bash
cast send <TRAP_ADDRESS> "submitVAAHash(uint256,bytes32)" <SEQ> <VAA_HASH> --private-key $OPERATOR_KEY
```

7. Read `collect()` payload

```bash
cast call <TRAP_ADDRESS> "collect()" 
# returns bytes; use `cast abi-decode` with the expected tuple to decode:
cast abi-decode "(address,uint256,uint256,uint256,uint256,uint256,uint256,uint8,bytes32,bool)" \
  $(cast call <TRAP_ADDRESS> "collect()" | tr -d '\n')
```

---

## drosera.toml — response function signature

Drosera will call your response contract with the fields collected by `collect()`. The exact response signature (and argument order) must match the trap `collect()` encoding.

Add or update this in `drosera.toml`:

```toml
[response]
contract = "0xYOUR_RESPONSE_CONTRACT_ADDRESS"
function = "respondWithBridgeAlert(address,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,bool)"
```

Parameter order explained (must match the `collect()` encoding):

1. `address bridge`
2. `uint8 reason`
3. `uint256 lastSeenSequence`
4. `uint256 currentSequence`
5. `uint256 lastGuardianIndex`
6. `uint256 currentGuardianIndex`
7. `uint256 backlog`
8. `uint256 lastTs`
9. `bytes32 vaaHash`
10. `bool conflict`

Important: order and types must exactly match — otherwise Drosera’s call will revert.

---

## Example ABI decode line

When you `cast call` the trap’s `collect()` you will get `bytes`. To decode:

```bash
# example: raw hex in $COLLECT_HEX
cast abi-decode "(address,uint256,uint256,uint256,uint256,uint256,uint256,uint8,bytes32,bool)" $COLLECT_HEX
```

This matches the ordering previously described (note: decode types align with the encoded order used in `collect()` — `reason` is `uint8` placed before `bytes32` and `bool` in the tuple).

---

## Suggested testing checklist

1. Deploy trap & response locally (anvil / Hardhat / Foundry fork).
2. Init trap and response; set bridge to a mock contract implementing the expected selectors.
3. Make the mock bridge return:

   * `lastProcessedTimestamp` within/outside thresholds
   * `unprocessedCount` across threshold
   * guardian index changes
   * sequence changes
4. Verify `collect()` encodes correct fields and order.
5. Call response contract `respondWithBridgeAlert(...)` manually with decoded values to ensure storage & event emission.
6. Test `submitVAAHash` behavior for same/different hashes to verify `conflictRecorded` toggles.

---

