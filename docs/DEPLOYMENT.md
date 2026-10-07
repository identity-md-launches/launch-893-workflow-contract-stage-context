# Deployment and operations handoff

## Artifacts and constructor order

This source contribution does not write `launch.json`. The manifest contributor should identify `LaunchToken` at `src/LaunchToken.sol` as the launch token and `GridMining` at `src/GridMining.sol` as the one application. Both identifiers fit the launch's 32-character ASCII limit. There are no linked libraries or contributor-deployed randomness adapters. Test helpers are not deployment artifacts.

Deploy the token before the game. `LaunchToken` has no constructor arguments. `GridMining` uses the following ordered, static, nonpayable constructor parameters:

| Position | Name | ABI type | Value or constraint |
| --- | --- | --- | --- |
| 1 | `gold_` | `address` | `$token`, the accepted LaunchToken |
| 2 | `coordinator_` | `address` | Verified target-chain Chainlink VRF v2.5 coordinator; **not supplied** |
| 3 | `keyHash_` | `bytes32` | Coordinator's supported nonzero gas lane; **not supplied** |
| 4 | `subscriptionId_` | `uint256` | Existing nonzero LINK-funded subscription; **not supplied** |
| 5 | `requestConfirmations_` | `uint16` | 3–200; select a chain/value-at-risk appropriate value |
| 6 | `callbackGasLimit_` | `uint32` | 100,000–2,500,000 and within coordinator limits; propose 150,000 |
| 7 | `roundDuration_` | `uint32` | 30–86,400 seconds; propose **90** |
| 8 | `oracleTimeout_` | `uint32` | 3,600–604,800 seconds per request/fulfillment window; propose **86,400** |
| 9 | `entryPrice_` | `uint128` | Nonzero native minor units per tile; propose **1000000000000000** (0.001 ETH on an ETH-native chain) |
| 10 | `rewardPerRound_` | `uint128` | Nonzero Gold minor units; propose **100000000000000000000** (100 Gold) |

These example economics are assumptions, not an approved chain configuration. Tests use a mock coordinator, subscription 1, arbitrary key hash 42, and three confirmations; none is a production choice. There is no `network.json` in the supplied inputs. The manifest/reviewer must resolve actual network, verified coordinator identity, key hash, subscription ID, and suitable confirmation/gas/time settings. Do not substitute an EOA or a mock. The constructor checks a nonzero coordinator address without executing or requiring external-chain code: the protected launch constructor check runs in an isolated EVM. Code existence, identity and configuration must therefore be verified on the target chain externally before admission/deployment. An incorrect address can only be repaired by redeploying.

All configuration is immutable. There is no initializer, owner, upgrade, coordinator setter, or constructor reliance on `msg.sender` for a privileged application role. The only constructor assignment involving `msg.sender` is the required token mint to its deployer. The factory need not and cannot initialize the game with a subsequent call. The external subscription's consumer registration and funding are operating prerequisites, not game initialization.

## Release responsibilities

- **Manifest contributor:** describe the accepted source and constructor arguments, using `$token` for the Gold address. Follow the canonical `evm_project` pool/currency guidance. Do not list factory-provided `MerkleDistributor` or `PoolInitializationGuard`. No policy signatures or publication artifacts are fabricated here.
- **Independent reviewer:** assess this source, tests and the completed manifest together, especially coordinator identity, subscription control, constructor values, timeout tradeoffs, payouts and token allocation. This builder's tests do not satisfy that separate review.
- **Services:** publish the source, attest the accepted artifacts and policy linkage, admit, deploy and verify the configured source/runtime, then supply deployment details to the frontend. No contributor broadcast or wallet key is needed.
- **Subscription operator:** create/retain a funded Chainlink VRF v2.5 subscription paid in LINK, authorize the final game address as a consumer (or authorize its verified predicted address in advance), monitor balance and latency, and select sufficient confirmations for the target chain. This external role can impair liveness by removing authorization or funding; it cannot withdraw game funds or set a winning word through the game interface.
- **Reward sponsors:** use `approve` followed by `fundRewards`, understanding that donations cannot be withdrawn. An exhausted reserve stops new rounds. There is no special sponsor share of the launch supply and no extra emission authority.
- **Keepers/users:** submit `startRound`, `closeRound`, `settleRound`, or `expireRound` as appropriate. These methods are permissionless and have no keeper bounty. An operator should monitor them; relying entirely on altruistic callers gives no liveness guarantee. Players pay transaction gas for their own entries and claims.
- **Frontend contributor:** show exact entry price, currently funded reward, deadline, status, selected tiles, random request/result, claim eligibility, and the loss/refund rules. Read `claimable` again before claiming because the last claim may include dust. Never promise that a 90-second entry window guarantees a 90-second final outcome or profit.

## Chain and oracle constraints

The game uses timestamps for durations and never uses block numbers, hashes, timestamps, or caller-supplied seeds for randomness. It calls the [Chainlink v2.5 subscription interface](https://docs.chain.link/vrf/v2-5/subscription/get-a-random-number) with one word and tagged `ExtraArgsV1(nativePayment: false)`; LINK is billed to the subscription. The immutable coordinator authenticates callbacks and verifies the cryptographic proof externally. The local mock demonstrates behavior only.

Use a chain with a verified compatible coordinator and EVM support for the pinned Paris-targeted Solidity output. No live network compatibility is claimed. zkSync Era's separate compiler requirements are outside this Solidity build. L2 sequencer downtime, censorship and timestamp behavior affect deadlines; confirmation and timeout selection need chain-specific review. Changing chain infrastructure later requires a new game deployment; outstanding claims on the old deployment remain available under its existing rules.

No deployment, subscription transaction, GitHub publication, IPFS publication, attestation, admission, or independent review was performed by this assignment.
