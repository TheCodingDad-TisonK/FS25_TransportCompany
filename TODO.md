# Transport Company — TODO

Operational task list. The v1.2.0.0 overhaul is built, released and deployed;
it is considered done when its PR merges to `main` and its in-game
verification checklist is green.

## v1.2.0.0 — Complete overhaul (built, shipped)

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
- [x] Release flow: version corrected to v1.2.0.0 (not v4.0.0.0; baseline is
      the v1.0.1.0 public release), tag + GitHub release published with the
      built zip, PR #5 updated, zip deployed to the active mods folder.
- [x] KingMods changelog written to the Desktop
      (`FS25_TransportCompany_KingMods_changelog.txt`).

## Verification (pending — needs you)

- [ ] PR #5 merged to `main` (Tyson merges).
- [ ] In-game checklist green (`IN-GAME-VERIFICATION-CHECKLIST.html` sections
      `tc-r1`..`tc-r4`). The game has not been launched since the v1.2.0.0
      deploy (log.txt last write is the pre-overhaul session). In particular
      the R3 discharging-match for every station type needs a real play
      session; a miss costs a Fleet line, never a job.

## Post-1.2 ideas (not scheduled)

- Custom HQ model, map navigation to a contract's pickup/drop-off,
  per-truck efficiency ratings, premium long-term contracts.
