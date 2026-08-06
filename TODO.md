# Transport Company — TODO

Operational task list. One release's tasks move to `Done` only when its PR is
merged to `main` and its in-game verification checklist is green.

## R2 · v2.1.0 — Economy & route core

- [ ] Distance-based bulk reward in `TransportCompanyContract.generate` using
      `calcDistanceFrom(sourcePlaceable.rootNode, destPlaceable.rootNode)` as
      the straight-line proxy; add `RATE_PER_METER` and calibrate so 1.x-era
      rewards are the low band.
- [ ] Pallet reward ties to live economy: `amount × REWARD_PER_OBJECT ×
      (0.5 + pricePerLiter × K)` instead of the flat 350/object.
- [ ] Capacity-aware amount sizing from the farm's owned trucks/trailers
      (`getAIFillUnits`); size to 1–3 trips, never an impossible one-trip ask.
- [ ] Route reasonableness: skip sub-50 m "moves", prefer AI-haulable pairs,
      weight source/dest pick by distance.
- [ ] Difficulty tiers (Standard / Urgent / Bulk) with reward + deadline
      modifiers; surface in dispatch rows and the detail panel.
- [ ] PDA detail rows: distance, est. fuel cost, est. profit.
- [ ] simtest5 additions: distance monotonicity, pallet economy scaling,
      capacity clamping.
- [ ] In-game: reward visibly scales with route length; no job exceeds the
      biggest owned trailer within ~3 trips; urgent pays more.
- [ ] Version bump, README/MODHUB/changelog, ROADMAP.md status → shipped.

## R3 · v2.2.0 — Self-haul vehicle attribution

- [ ] In-game spike: confirm `Dischargeable:getCurrentDischargeObject` on the
      truck's child trailer (or `FillTrigger.vehiclesTriggerCount` on the
      station trigger) reliably identifies the tipping vehicle for FS25
      stations. `UnloadingStation` is absent from the references, so this must
      be observed in game, not assumed.
- [ ] Correlate the discharging vehicle with the station that just credited;
      credit that truck's `addRevenue`/`addJob` for the self-haul portion.
- [ ] Fallback chain: hired → `acceptedTruckUniqueId`; self-haul →
      discharging-vehicle match; else leave truck books uncredited.
- [ ] Extend `BooksEvent` snapshot to carry the new self-haul revenue/jobs.
- [ ] simtest2 extension with a stubbed discharging-vehicle model.
- [ ] In-game: self-hauled job shows revenue + job on the truck that tipped.

## R4 · v3.0.0 — Business sim layer

- [ ] Named driver roster (`TransportCompanyDriver`): hire/fire at HQ, base
      wage + per-job share, experience growth, assigned truck.
- [ ] Reputation/XP: on-time completion +, expired/returned −; gates board
      size, driver cap, premium routes.
- [ ] HQ upgrade tiers bought in-PDA (capacity, driver cap, board size,
      premium unlocks).
- [ ] Maintenance & depreciation: service cost at km milestones, depreciation
      on the books.
- [ ] Ledger depth: per-season/month P&L history, cost-per-km, fleet
      utilisation, configurable retention.
- [ ] simtest6+ for driver wages/XP, maintenance thresholds, ledger rollup.

## Done

- [x] R1 · v2.0.0 per-farm companies (2026-08-06, development)
