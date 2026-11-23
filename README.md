# Autopilot Allowance

**A personal recurring-payment vault that runs itself. Set it and forget it.**

Deposit once, set one allowance plan - recipient, amount, interval, start - and
the network itself keeps paying on schedule. No keeper bot, no server, no cron
job on someone's laptop: the plan is enforced by a reactive contract watching
the chain.

Built for the **Reactive Omni Buildathon** - *Set It and Forget It* track.

## How it works

```
owner (human)                     Reactive Network                    origin chain (Ethereum Sepolia)
     |                                   |                                    |
     | deploy + fund AllowanceVault      |                                    |
     | setPlan(recipient, amount, ...)   |                                    |
     |----------------------------------->|  PlanSet event                    |
     |                                   |  AllowanceAutopilot mirrors plan  |
     |        (owner walks away)          |                                    |
     |                                   |  CRON100 tick (~2 min)            |
     |                                   |  plan due? -> request callback ---|--> vault.pay()
     |                                   |                                    |   recipient gets paid
     |                                   |                                    |   Paid event
```

Two contracts:

| Contract | Chain | Role |
| --- | --- | --- |
| `AllowanceAutopilot.sol` | Reactive (Lasna testnet, 5318007) | Subscribes to the vault's `PlanSet`/`PlanCancelled` events and to the network's own `Cron100` events. Every tick it checks whether the mirrored plan is due and requests a callback. |
| `AllowanceVault.sol` | Origin/destination (Ethereum Sepolia, 11155111) | Holds the owner's deposit, stores the plan, and pays out. Payouts are only accepted from the Reactive callback proxy on behalf of the autopilot contract. |

Safety properties:

- Funds can only leave the vault to the plan's recipient, in the plan's amount,
  via a callback authenticated by the network (the callback proxy plus the
  injected reactive-contract address).
- The owner can cancel the plan or withdraw everything at any time, from the
  origin chain alone.
- Each plan has a monotonic ID. Each callback carries its plan ID and scheduled
  slot. The vault rejects old-plan callbacks, early payments, off-grid slots,
  and slots already consumed. This protection lives on the destination chain.
- Missed or failed slots are not retried automatically. Later scheduled slots
  can proceed without paying arrears. This is best-effort automation, not a
  guaranteed billing system.
- The autopilot pays for its own ticks and can be paused (`pause()` unsubscribes
  from CRON) and refunded (`withdraw()`). The destination vault also needs native
  tokens for callback fees, in addition to the intended payout balance.
- The inherited service-provider billing function can pay network fees from the
  contract balance. Payout principal and fee reserve are not isolated yet.
- Timing is approximate: a due payment waits for a network tick and cross-chain
  delivery. Cancellation on the vault takes effect immediately for later callbacks;
  it cannot reverse a payment already included on the destination chain.

## Deployed contracts (Lasna testnet + Ethereum Sepolia)

| Contract | Chain | Address |
| --- | --- | --- |
| `AllowanceVault` | Ethereum Sepolia (11155111) | [`0xfCE2AaC5c2B6e83D504AAF9844ed92ABbba91A10`](https://sepolia.etherscan.io/address/0xfCE2AaC5c2B6e83D504AAF9844ed92ABbba91A10) |
| `AllowanceAutopilot` | Reactive Lasna (5318007) | [`0xafBF77C5587E365712416D6EFF9A40FDF2545F95`](https://lasna.reactscan.net/address/0xafBF77C5587E365712416D6EFF9A40FDF2545F95) |

Deployer: `0x6f59ab1977DF350d1FbBE379EEE6D45AEB766353` (testnet only).

Verified end-to-end loop (2026-11-23, all on public explorers):

1. Sepolia ETH swapped to lREACT via the official faucet contract - tx
   [`0x6ba839899a2374368d8bd5e95b1aee23cf032105ef173e8155d31550b2463996`](https://sepolia.etherscan.io/tx/0x6ba839899a2374368d8bd5e95b1aee23cf032105ef173e8155d31550b2463996)
2. Vault deployed - tx [`0xa25c3b2ad7e5e84c2fc50afc6c105579c489f2a17a7263bf56b345ce970bb499`](https://sepolia.etherscan.io/tx/0xa25c3b2ad7e5e84c2fc50afc6c105579c489f2a17a7263bf56b345ce970bb499)
   (autopilot address pre-committed as the deployer's CREATE address at Lasna nonce 0)
3. Autopilot deployed with 1.5 lREACT - tx
   [`0x49131f1a44e73f448cf2e5ef41da00883005275db40055d921e9d524529cede0`](https://lasna.reactscan.net/tx/0x49131f1a44e73f448cf2e5ef41da00883005275db40055d921e9d524529cede0),
   landed exactly at the pre-committed address `0xafBF77C5587E365712416D6EFF9A40FDF2545F95`
4. Vault funded with 0.03 Sepolia ETH - tx [`0x84ade922774b5b6bfc6daed23c8b3a7f4bd84536708bbeb3c014b5efe5d94e81`](https://sepolia.etherscan.io/tx/0x84ade922774b5b6bfc6daed23c8b3a7f4bd84536708bbeb3c014b5efe5d94e81)
5. `setPlan(0.005 ETH / 600s)` - tx [`0x7867c69565178e5fc8a9206a8caa40cd9f6502896ac04429557137e34cd39dd0`](https://sepolia.etherscan.io/tx/0x7867c69565178e5fc8a9206a8caa40cd9f6502896ac04429557137e34cd39dd0)
6. CRON tick -> autopilot dispatched payout #3 -> callback delivered and `Paid`
   emitted, 0.005 ETH to the plan recipient - destination tx
   [`0x8bd0c8f25445396d9e6ca91a43ee596a5300971d6d65007103e78d49619c2d0f`](https://sepolia.etherscan.io/tx/0x8bd0c8f25445396d9e6ca91a43ee596a5300971d6d65007103e78d49619c2d0f)
7. Four more consecutive payouts, one per 600s slot:
   [`0x2349ce37`](https://sepolia.etherscan.io/tx/0x2349ce37e78c06ae239573387f158219461d2e5170ec590ec2be77a6a8df752d),
   [`0xa59cdc8b`](https://sepolia.etherscan.io/tx/0xa59cdc8b6490553dc17af81656ebb7f10c10c784e3b88fcb9c70fd167f1d3a23),
   [`0xa841b8bd`](https://sepolia.etherscan.io/tx/0xa841b8bd11216fd7421c6fc3e2250733659bacef833bf6b836d4c6c82d036c97),
   [`0xce438f49`](https://sepolia.etherscan.io/tx/0xce438f499b9116a66c09661e87d7062fed55db1e109f710e7446e773516ad85c)
8. `cancelPlan()` - tx [`0xf6ab92f6`](https://sepolia.etherscan.io/tx/0xf6ab92f6edc67940fef6cbb6597f9ebaaaf826301f193dea7323df1e100008b5);
   the autopilot mirrored the cancellation and dispatches stopped (verified on Lasna),
   then the remaining vault balance was withdrawn - tx
   [`0xd8d8f14b`](https://sepolia.etherscan.io/tx/0xd8d8f14b486f1129f91dede7e9b4a9de6f0b0bb2c9b25fa9d54ff9e3ffe2b703) - full hash `0xd8d8f14b486f1129f91dede7e9b4a9de6f0b0bb2c9b25fa9d54ff9e3ffe2b703`

Lesson learned on gas: the callback proxy forwards less gas than the requested
limit (its own overhead plus billing), so the first two dispatches (200k, 400k)
failed OutOfGas while still being billed a small fee; 1,000,000 works. Slots
that failed were simply skipped, as designed, and the next slot paid normally.

## Build and test

```bash
forge build
forge test -v   # 22 tests: replay fuzz (256 cases), slot/plan-version guards, forged-origin rejection
```

## How this maps to the track criteria

- **Execution** - the full loop ran on public testnets: 7 dispatches, 5 consecutive
  successful payouts delivered by the network's own callback proxy, then a clean
  cancel and withdrawal. Every step has a transaction hash above.
- **Integration** - the reactive contract does the real work: it mirrors the plan
  from vault events and decides payouts from network CRON ticks alone. No bot, no
  server, no keeper wallet anywhere in the loop.
- **Usefulness** - a personal automation anyone can use: recurring allowance,
  subscription, or savings transfer. Deposit once, set one plan, walk away.
- **Craft** - destination-side safety (plan versioning, schedule-slot verification,
  replay rejection), 22 local tests including a 256-case replay fuzz, honest
  handling of failed slots, and a live dashboard reading both chains.

## Demo

- Live dashboard (reads both chains from public RPCs): linked in the submission.
- Demo video: linked in the submission.

## Track checklist

- [x] Personal automation anyone can build (deposit, set plan, walk away)
- [x] Reactive contract doing the real work (CRON subscription + event mirroring + callbacks)
- [x] Deployed contract addresses
- [x] Transaction hashes showing the full loop (PlanSet -> CRON tick -> callback -> Paid)
- [ ] Demo video under 3 minutes

## License

MIT

## Development status

Prototype only. Not audited, not suitable for real funds. Deployed on Lasna
testnet + Ethereum Sepolia with a verified end-to-end loop (see above). Local
suite: 22 tests, including a 256-case replay fuzz test.
System calls are mocked locally; these tests do not prove network integration.

The vault address is fixed at autopilot deployment. Deploy the vault first using
an explicitly predicted autopilot CREATE address (verify deployer nonce), then
deploy the autopilot against that vault, or use a deterministic deployment factory.
Do not substitute a different address after deployment.
