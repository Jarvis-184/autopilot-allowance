# Autopilot Allowance

**A personal recurring-payment vault that runs itself. Set it and forget it.**

Deposit once, set one allowance plan — recipient, amount, interval, start — and
the network itself keeps paying on schedule. No keeper bot, no server, no cron
job on someone's laptop: the plan is enforced by a reactive contract watching
the chain.

Built for the **Reactive Omni Buildathon** — *Set It and Forget It* track.

## How it works

```
owner (human)                     Reactive Network                    origin chain (Base Sepolia)
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
| `AllowanceVault.sol` | Origin/destination (Base Sepolia, 84532) | Holds the owner's deposit, stores the plan, and pays out. Payouts are only accepted from the Reactive callback proxy on behalf of the autopilot contract. |

Safety properties:

- Funds can only leave the vault to the plan's recipient, in the plan's amount,
  via a callback authenticated by the network (the callback proxy plus the
  injected reactive-contract address).
- The owner can cancel the plan or withdraw everything at any time, from the
  origin chain alone.
- The autopilot advances the schedule when it dispatches a payout, so a failed
  callback never causes a double pay; it pays for its own ticks and can be
  paused (`pause()` unsubscribes from CRON) and refunded (`withdraw()`).

## Deployed contracts (Lasna testnet + Base Sepolia)

_To be filled in at submission time, with the full event-to-callback loop's
transaction hashes._

## Build

```bash
forge build
```

## Track checklist

- [x] Personal automation anyone can build (deposit, set plan, walk away)
- [x] Reactive contract doing the real work (CRON subscription + event mirroring + callbacks)
- [ ] Deployed contract addresses
- [ ] Transaction hashes showing the full loop (PlanSet -> CRON tick -> callback -> Paid)
- [ ] Demo video under 3 minutes

## License

MIT
