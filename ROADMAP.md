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
| **R3 · v2.2.0** | Self-haul attribution | Detect the discharging vehicle and credit its books for self-hauled jobs (engine spike first) | ⬜ Next |
| **R4 · v3.0.0** | Business sim | Named driver roster, reputation/XP, HQ upgrade tiers, maintenance & depreciation, ledger P&L depth | ⬜ |

## Principles

- **Distance pricing uses straight-line distance as the documented proxy.** The
  FS25 reference set exposes no road/path-length API (`AIPathUtil`,
  `getPathLength`, `TransportMission` source are all absent). In-game
  calibration of `RATE_PER_METER` beats pretending we have the base game's
  curve. Revisit only if a road-length API is confirmed.
- **Attribution is additive, never load-bearing.** Delivery detection and
  payout correctness must not depend on knowing which truck tipped; per-truck
  books are a display layer on top.
- **One PR per release.** Every release is ModHub-submittable on its own and
  does not require the ones after it.

## Out of scope (for now)

- Custom HQ model (needs art; the base `easyShed01` stays).
- New map content or stations (contracts must keep working with zero map
  preparation).
- Cross-mod APIs with the Realistic Farming ecosystem.
