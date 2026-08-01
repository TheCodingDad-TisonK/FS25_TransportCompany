# FS25 Transport Company

Own and operate a trucking company in Farming Simulator 25.

Buy the **Transport Company HQ** from the shop and place it on your farm. A dispatch
office opens in the in-game menu with four sections: Dispatch, Fleet, Ledger and
Settings. Freight jobs are generated from the stations already on your map — haul them
yourself, or hand one to a hired driver and let the base game AI run it.

Everything uses stock FS25 behaviour: the base AI, the base finance system, base menu
widgets, savegame persistence and multiplayer.

---

## Getting started

1. Buy the **Transport Company HQ** — shop → Buildings → Sheds.
2. Place it on your farm. The contract board fills as soon as it is standing.
3. Open the in-game menu and pick the truck tab.

The tab is always visible, even before you own an HQ — it tells you what to do instead
of hiding.

## Dispatch

Each job names its goods, route, reward and status. Selecting one shows the pickup and
drop-off stations, the amount, the deadline and a progress bar.

- **Accept contract** — haul it yourself. Load at the pickup station, tip at the
  destination. Progress updates as you tip, and over-tipping rolls onto your next open
  job for the same goods rather than being wasted.
- **Hire driver** — needs an AI-capable truck your farm owns, with both loading and
  discharge nodes (in practice a tipper or trailer rig the base AI accepts). The driver
  keeps a configurable share of the reward; the company banks the rest.

The fill type and destination must match exactly, and only the farm that accepted a
contract is credited.

## Fleet

Per-truck books: distance, fuel burned valued at the current economy price, jobs
completed and profit.

Only vehicles the base game classes as `statsType="truck"` enrol — many vehicles are
`tractor` and will not appear. That is deliberate, not a bug. Newly bought trucks are
picked up within ten seconds.

## Ledger

A company summary followed by finished and expired jobs, newest first. Revenue, wages
and job count are tracked at company level, because a load you tip yourself cannot be
attributed to a specific truck — the station reports liters and a fill position, never
the vehicle.

## Settings

| Setting | Default | Scope |
|---|---|---|
| Company enabled | on | server |
| Contracts on the board | 5 | server |
| Deadline (days) | 7 | server |
| Driver wage share (%) | 20 | server |
| Notifications | on | server |
| Debug logging | off | per player |

Server-scoped settings can only be changed by the host. A client editing them locally
would quietly disagree with everyone else about board size, deadlines and wages.

## Multiplayer

Contract state, payouts and AI dispatch are server-authoritative. Clients request
changes and receive the result; they build their own fleet roster from the synced
vehicle list so the Fleet tab works everywhere.

## Console commands

Available with the developer console enabled.

| Command | Purpose |
|---|---|
| `tc_debug` | toggle verbose logging |
| `tc_generate_contract` | force a job onto the board |
| `tc_list_contracts` | ids, states, progress |
| `tc_list_trucks` | what actually enrolled |
| `tc_reset_settings` | back to defaults |

---

## Building

```
py build.py            # build the zip
py build.py --deploy   # build and copy to the mods folder
```

`tools/` and `tests/` are excluded from the zip.

## Tests

```
py tests/run.py        # needs: pip install lupa
```

Four suites, 97 assertions. They stub the engine surface and load the **real** mod
sources under LuaJIT 5.1 — the same runtime FS25 uses — so they exercise shipped code
rather than a copy. Several regressions were caught here before reaching the game.

`tests/luacheck.py` parses every Lua file without running it.

## Artwork

```
py tools/build_icons.py
```

Regenerates `icon_source.png`, the store and tab textures, and encodes
`textures/icon.dds` as 512×512 DXT1. FS25 warns about raw-format textures and does CPU
mip generation for PNG, so the shipped icon is DDS.
