## What Does This PR Do?

<!-- One paragraph summary. What changed and why? -->

## Related Issue

<!-- Closes #, Fixes #, or "no issue" -->

## Type of Change

- [ ] Bug fix
- [ ] New feature (contract, fleet, driver, setting, UI)
- [ ] Refactor / code quality
- [ ] Documentation / translations
- [ ] Build / tooling

## How Was This Tested?

- [ ] Singleplayer - loaded a savegame, no errors in log.txt
- [ ] Multiplayer - tested as host and/or client

- [ ] Relevant console commands ran (`tc_list_contracts`, `tc_list_trucks`, etc.)

<!-- Describe what specifically you tested and any edge cases you checked -->

## Checklist

- [ ] I read `DEVELOPMENT.md` before writing code
- [ ] I targeted the `development` branch (not `main`)
- [ ] My change touches only what it needs to - no unrelated edits
- [ ] If I added a setting: one entry in `TransportCompanySettings.lua` + `transportCompany_setting_*` / `transportCompany_settingDesc_*` translations in `l10n/l10n_en.xml` and `l10n/l10n_de.xml`
- [ ] If I changed contract/economy values: they're in `TransportCompanyContract.lua` constants, not hardcoded
- [ ] If I changed behaviour: `docs/modhub_changelog.txt` has an entry under the correct version
- [ ] No `assert()` calls - errors are handled gracefully with `pcall()`
- [ ] No Lua 5.2+ syntax (`goto`, `continue`, `os.time()`, etc.)
- [ ] Tests pass: `py tests/run.py`

## Screenshots / Log Output (if relevant)

<!-- Paste a log excerpt or screenshot if this fixes a visible bug or changes UI -->
