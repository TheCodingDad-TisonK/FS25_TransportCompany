# Transport Company — Roadmap

Standalone mod, outside the Realistic Farming ecosystem. This roadmap tracks the
overhaul of the current gameplay core; the engineering plumbing (MP events,
delivery hooks, stuck-driver watchdog, settings schema, test harness) is
treated as done and stable.

## Release plan

| Release | Theme | Contents | Status |
|---|---|---|---|
| **R1 · v2.0.0** | Per-farm companies | Company class, manager→registrar, per-farm events/persistence/settings, log hygiene, generator tests, legacy save migration | ✅ Shipped (development) |
| **R2 · v2.1.0** | Economy & route core | Distance-based reward, pallet economy link, capacity-aware sizing, route reasonableness, AI-route preference, difficulty tiers, PDA route economics | ✅ Shipped (development) |
| **R3 · v2.2.0** | Self-haul attribution | Discharging-vehicle detection credits the tipping truck for self-hauled jobs; additive, never load-bearing | ✅ Shipped (development) |
| **R4 · v3.0.0** | Business sim | Named driver roster, weekly wages & experience, reputation/level, HQ upgrade tiers, maintenance, weekly P&L | ✅ Shipped (development) |

## Post-R4 ideas (not yet scheduled)

- Custom HQ model (needs art; the base `easyShed01` stays).
- Map navigation to a contract's pickup/drop-off.
- Per-truck efficiency ratings feeding a smarter `EST_FUEL_L_PER_KM`.
- Premium "long-term" contracts (supply X per week).

## Principles

- **Distance pricing uses straight-line distance as the documented proxy.** The
  FS25 reference set exposes no road/path-length API (`AIPathUtil`,
  `getPathLength`, `TransportMission` source are all absent). In-game
  calibration of `RATE_PER_METER` beats pretending we have the base game's
  curve. Revisit only if a road-length API is confirmed.
- **Attribution is additive, never load-bearing.** Delivery detection and
  payout correctness must not depend on knowing which truck tipped; per-truck
  books are a display layer on top. R3's discharging-vehicle detection
  (`getCurrentDischargeNode` + `getCurrentDischargeObject`, Dischargeable.md)
  follows this rule; if it cannot match a truck in a given setup, the job
  still completes and pays, it just is not pinned to a truck.
- **One PR per release.** Every release is ModHub-submittable on its own and
  does not require the ones after it.

## Out of scope (for now)

- Custom HQ model (needs art; the base `easyShed01` stays).
- New map content or stations (contracts must keep working with zero map
  preparation).
- Cross-mod APIs with the Realistic Farming ecosystem.
- Map navigation to a contract's pickup/drop-off; per-truck efficiency
  ratings feeding a smarter fuel estimate; premium long-term contracts.
