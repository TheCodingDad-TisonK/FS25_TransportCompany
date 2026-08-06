# Transport Company — TODO

Operational task list. One release's tasks move to `Done` only when its PR is
merged to `main` and its in-game verification checklist is green.

## R2 · v2.1.0 — Economy & route core

- [x] Distance-based bulk reward in `TransportCompanyContract.generate` using
      `calcDistanceFrom` (straight-line proxy); `RATE_PER_METER` calibrated so
      1.x-era rewards are the low band.
- [x] Pallet reward ties to live economy: `computePalletReward` scales the
      per-object base by price (gold > flour).
- [x] Capacity-aware amount sizing from the farm's owned trucks/trailers
      (`getMaxTripCapacity` + `getVehicleAiCapacity`); size to ≤3 trips.
- [x] Route reasonableness: `MIN_ROUTE_DISTANCE_M` floor, AI-pair preference,
      `pickFarthest` bias toward longer routes.
- [x] Difficulty tiers (Standard / Urgent / Bulk) with reward + deadline
      modifiers; surfaced in the detail panel.
- [x] PDA detail rows: distance, est. fuel cost, est. profit.
- [x] simtest5 additions: distance monotonicity, pallet economy scaling,
      capacity clamp, tier-aware deadline.

## R3 · v2.2.0 — Self-haul vehicle attribution

- [x] In-game spike: `Dischargeable:getCurrentDischargeNode` +
      `getCurrentDischargeObject` (Dischargeable.md:846-895) confirmed as the
      documented vehicle-side signal; implemented with pcall guards.
- [x] Correlate the discharging vehicle with the station that just credited;
      credit that truck's `addRevenue`/`addJob` for the self-haul portion.
- [x] Fallback chain: hired → `acceptedTruckUniqueId`; self-haul →
      `deliveryTruckUniqueId` (the discharging match); else leave truck books
      uncredited.
- [x] simtest2 attribution suite: tipping truck credited, idle truck not,
      delivery still pays when nothing matches.
- [x] In-game note: the discharging match needs a real play session to
      confirm the exact object identity for every station type; the additive
      design means a miss only costs a Fleet line, never the job.

## R4 · v3.0.0 — Business sim layer

- [x] Named driver roster (`TransportCompanyDriver`): hire/fire at the HQ,
      base wage + experience progression, assigned truck.
- [x] Reputation/level: on-time completion +, expiry −; level gates the
      driver cap.
- [x] HQ upgrade tiers bought in-PDA (board size + driver cap per tier).
- [x] Maintenance: service at km milestones booked as a truck + company
      expense.
- [x] Weekly wage payment from the farm balance, once a game week.
- [x] Weekly P&L rollup in the Ledger detail panel.
- [x] simtest6: drivers, cap gating, reputation clamps, HQ upgrades,
      maintenance, wages, P&L rollup, farm-ownership validation.

## Done

- [x] R1 · v2.0.0 per-farm companies (2026-08-06, development)
- [x] R2 · v2.1.0 economy & route core (2026-08-06, development)
- [x] R3 · v2.2.0 self-haul attribution (2026-08-06, development)
- [x] R4 · v3.0.0 business sim (2026-08-06, development)
