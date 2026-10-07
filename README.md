# Gold Grid Mining

Gold is a 5×5 grid game with native-currency entries, verifiable asynchronous draws, shared prizes, and prefunded Gold rewards. This repository delivers the contract stage: Solidity source, offline dependencies, tests, ABI exports, and a deployment/review handoff. Publishing, the independently authored `launch.json`, independent review, admission, deployment, and the IPFS frontend belong to the subsequent contributors and services.

## Scope and assumptions

The approved brief supplies the name/symbol **Gold** and a reference to SLVR, but no exact economics or target network. [SLVR's public introduction](https://slvr.fun/about) describes 25-square rounds with native-currency commitments and token rewards. This implementation adopts that basic grid model. Its explicit design assumptions are:

- One fixed-price ticket per wallet per tile per round. A wallet may select any subset of 25 tiles and add distinct tiles before closing. This is a ticket rule, not Sybil resistance; multiple wallets can hold more tickets.
- One randomly selected tile among all 25. Winners split the entire round's entry pot and one fixed Gold reward equally. Losing tiles receive nothing when there are winners. If the winning tile is empty, everyone receives a full entry refund and Gold is returned to the reward reserve.
- A proposed 90-second entry window; draw fulfillment is asynchronous and has no promised completion time within that window. Rounds are opened by a transaction, with at most one unfinished round.
- No game fees, jackpot, trade tax, insurance market, staking, buyback, automatic re-entry, token issuance, or privileged fund withdrawals. These are not part of this implementation. Mining means participating in this game, not proof-of-work or guaranteed yield.

Gold cannot reproduce the reference project's freshly minted mining rewards: the launch requires a fixed supply of **1,000,000,000 Gold**, **18 decimals**, all initially minted to the deploying factory. `LaunchToken` takes no arguments and has no public mint, burn, owner, pause, blocklist, fee, or upgrade function. Rewards use existing Gold voluntarily donated after deployment; the application constructor never moves the launch supply.

## Build and checks

Foundry with Solidity **0.8.26** is required. The compiler is pinned by version, bytecode metadata hashing is disabled, and the EVM target is Paris. All Solidity dependencies are ordinary vendored files. No npm, downloads, environment variables, RPC endpoint, filesystem cheatcode permissions, or FFI are needed to build or run the tests with the compiler installed.

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abi.py --check
```

The tests cover token supply/transfers/allowances and prohibited administration selectors; constructor validation; factory-style CREATE2 deployment and preservation of supply; runtime size and forbidden-opcode scanning; entry/round boundaries; duplicate and invalid actions; reserves, prizes, division dust, and full refunds; request failures, missing/late/malformed/replayed VRF callbacks; failed token and native payouts; reentrancy; callback gas; randomized grid outcomes; and stateful conservation of funds.

See [the ABI guide](docs/ABI.md), [deployment parameters](docs/DEPLOYMENT.md), and [security/review handoff](docs/SECURITY.md). These checks are local evidence, not an independent audit.

## Playing and funding

1. A Gold holder approves an exact donation amount and calls `fundRewards(amount)`. Donations are irrevocable and support future rounds. Transfers made directly to the contract do **not** fund the tracked reward reserve.
2. Anyone calls `startRound()`. It reserves `rewardPerRound` before accepting any entry. If Gold runs out, no new round can open.
3. Call `enter(roundId, tiles)` with exactly `popcount(tiles) * entryPrice` native currency. Tile `i` is bit `i`; row/column are `i / 5` and `i % 5`. For example, tiles 0, 6, and 24 use mask `16777281`. Entries close at `closesAt`, with equality already too late. The explicit round ID protects delayed transactions from entering a different round.
4. After closing, anyone calls `closeRound(roundId)`. Empty rounds recycle the Gold immediately; nonempty rounds request one Chainlink VRF word. A separately funded LINK subscription pays the oracle, never the players' entry pot.
5. A valid coordinator callback stores the word. Anyone then calls `settleRound(roundId)`. The winning tile is `randomWord % 25`. Settlement does not send funds or loop over players.
6. Each eligible wallet calls `claim(roundId, recipient)` for its prize or refund. Both assets go to that recipient. Claims have no deadline; old claims remain available while subsequent rounds run. Rejected transfers revert the entire claim so the player can retry with a different recipient.

The first `winners - 1` winning claims receive `floor(pot / winners)` native units and `floor(rewardPerRound / winners)` Gold minor units. The last winning claimant receives the remaining amounts, including all rounding dust (less than `winners` minor units of each asset). Claim order can affect only that dust. No unclaimed funds can be swept by a keeper or administrator.

If no request is accepted before `closesAt + oracleTimeout`, anyone can expire the round. An accepted request gets a fulfillment deadline of `request time + oracleTimeout`. If no timely result is stored, anyone can expire it at or after that deadline and players recover their full entry payments. At the deadline, callbacks are already ignored, regardless of transaction ordering. A result stored before the deadline can never be expired, and a round cannot reroll an accepted request. Chain censorship or lack of a keeper can still delay actual withdrawals; the clock alone does not execute transactions.

## Custody and launch economics

`nativeLiability` tracks entries still owed as prizes or refunds. `availableRewards` tracks donations available for future rounds; `reservedRewards` covers open rounds and unpaid prizes. With no direct donations, contract native balance equals `nativeLiability` and Gold balance equals `availableRewards + reservedRewards`. Forced native currency or direct token transfers are surplus: they cannot change prizes and have no recovery path. Use the documented funding and entry methods.

The factory performs the launch allocation, not the token or game: 10% goes to the swarm (2% accepted contributors and 8% paired seats), and 90% is the requester's share, including the policy's liquidity allocation. The default liquidity contribution is 80% of total supply unless the requester chose otherwise. No part of those allocations is automatically assigned to this game. Sponsors must acquire or receive Gold before donating it.

The factory supplies the reward distributor, pool and initialization guard. Its trading fees come from the network's LaunchFees configuration; the manifest admission field `fee: 3000` does not describe the effective pool trading fee. The game and Gold token add no trading fee. Frontends must use the exact deployed pool key from the service handoff.
