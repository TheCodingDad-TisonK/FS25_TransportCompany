# Transport Company — TODO

Operational task list. The v1.2.0.0 overhaul is built and shipped on
`development`; it is considered done when its PR merges to `main` and its
in-game verification checklist is green.

## v1.2.0.0 — Complete overhaul (all phases built, shipped on development)

Built in four internal phases that folded into one release.

- [x] R1 · Per-farm companies: `TransportCompanyCompany`, manager→registrar,
      per-farm events/persistence/settings, log hygiene, legacy save migration.
- [x] R2 · Economy & route core: distance-driven reward, economy-priced
      pallets, capacity-aware sizing, route reasonableness, tiers, PDA route
      economics.
- [x] R3 · Self-haul attribution: discharging-vehicle detection credits the
      tipping truck; additive, never load-bearing.
- [x] R4 · Business sim: named driver roster, reputation/level, HQ upgrade
      tiers, maintenance, weekly P&L.

## Verification (pending)

- [ ] PR merged to `main` (Tyson merges).
- [ ] In-game checklist green (`IN-GAME-VERIFICATION-CHECKLIST.html` sections
      `tc-r1`..`tc-r4`). In particular the R3 discharging-match for every
      station type needs a real play session; a miss costs a Fleet line, never
      a job.

## Post-1.2 ideas (not scheduled)

- Custom HQ model, map navigation to a contract's pickup/drop-off,
  per-truck efficiency ratings, premium long-term contracts.
