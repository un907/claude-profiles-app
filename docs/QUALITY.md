# Quality metrics

Numbers produced by `Scripts/quality-metrics.sh` (output: `dist/metrics/metrics.json` and `metrics.md`). CI runs the lint / complexity / duplication subset and fails when a value exceeds `Scripts/quality-thresholds.env` (ratchet: ceilings only go down).

## Baseline (2026-10-07)

Measured on macOS 27.0 (Apple silicon) with Swift 6.4 (Xcode 27). Static metrics and mutation: `Scripts/quality-metrics.sh --skip-perf` at 2026-10-07T14:42+09:00. Runtime metrics: full run at 2026-10-07T14:33+09:00 on the same code before a refactor that only split `CLIShimStore.synchronize` and moved two model methods into an extension.

| Metric | Value | Command / source | Tool version |
|---|---|---|---|
| SwiftLint warnings | 1414 | `swiftlint lint --quiet --reporter json` with `.swiftlint.yml` | SwiftLint 0.65.1 |
| SwiftLint errors | 0 | same | SwiftLint 0.65.1 |
| Compiler warnings | 0 | clean `swift build -c release` in a fresh scratch path, unique `warning:` lines | Swift 6.4 |
| Functions | 98 | `lizard Sources --csv` | lizard 1.24.1 |
| Average CCN | 3.13 | same | lizard 1.24.1 |
| Max CCN | 19 | `SharedConfigurationParityStore.prepare` | lizard 1.24.1 |
| Functions with CCN > 10 | 1 | same | lizard 1.24.1 |
| Duplicated lines | 1.22 % (2 clones) | `npx --yes jscpd@5.4.0 Sources --format swift` (min-tokens 50) | jscpd 5.4.0 |
| Mutation score | 57 % (46 of 80 mutants killed) | `muter run` with `muter.conf.yml`, operators RelationalOperatorReplacement, RemoveSideEffects, ChangeLogicalConnector | muter 16 |
| Launch time | 80.6 ms mean (σ 7.4, min 74.4, max 99.9) | `hyperfine --warmup 2 --runs 10 --prepare wait-gone.sh launch-once.sh` | hyperfine 1.21.0 |
| Idle RSS (20 s) | 44.1 MB | `ps -o rss=` 20 s after launch | macOS ps |
| Idle RSS growth (20 s → 120 s) | −7.2 MB | difference of two `ps -o rss=` samples | macOS ps |
| Idle CPU | 1.40 % | mean of the last 2 of 3 `top -l 3 -s 2` samples | macOS top |
| Leaks | not measurable | `leaks <pid>` | macOS leaks |

Mutation score per file: ProcessSnapshot.swift 100 %, CLIShimStore.swift 70 %, SharedMCPConfigurationStore.swift 70 %, SharedConfigurationParityStore.swift 52 %, SharedProjectsStore.swift 40 %. The weakest files (SharedProjectsStore, SharedConfigurationParityStore) are where new tests pay off most.

History: the first baseline on 2026-10-06 (before the CLI command feature and before `no_extension_access_modifier` was disabled) was 1169 warnings and 3 errors, 80 functions, 1 function over CCN 10, 1.5 % duplication and a 53 % mutation score (32 of 60). The CLI command feature added 245 SwiftLint warnings, mostly `explicit_type_interface`, `contrasted_opening_brace` and `prefer_nimble`, which the existing code does not follow either.

## Notes on the measurements

- **SwiftLint configuration.** Every non-analyzer opt-in rule is enabled except `no_extension_access_modifier`, which is the exact opposite of the enabled `extension_access_modifier`; keeping both would flag every extension.
- **Mutation scope.** Only `Sources/ClaudeProfilesCore` is mutated (`muter.conf.yml`). `Sources/ClaudeProfilesApp` (SwiftUI views, AppKit glue, Sparkle wiring) has no unit tests, so including it would measure missing tests rather than test strength.
- **SwapTernary is not used.** muter 16 turns `c ? x is A : x is B` into code that does not compile, which aborts the whole run. The other three operators are passed explicitly.
- **Launch time.** Each timed run starts only after the previous instance is gone both as a process and as a LaunchServices registration (`--prepare wait-gone.sh`), and the timer stops when LaunchServices lists the new process's own PID. An earlier probe matched any registration of the bundle ID and produced impossible values (minimum 13 ms); those numbers are discarded.
- **Leaks.** `leaks` cannot be measured on ad-hoc signed builds: without the `get-task-allow` entitlement the process is "not debuggable", `leaks` only sees read-only memory, and its count is meaningless. `leaks` is recorded as null and idle RSS growth is used as the substitute signal.
- **Runtime numbers can be disturbed by use.** The perf section runs the app for about two minutes. During the 2026-10-07 run a profile was opened from the menu bar while the app was idling, so the RSS and CPU values include that activity.
- **The perf section terminates every running `ClaudeProfilesApp`**, including an installed copy, because the launcher holds a single-instance lock. Restart the installed app afterwards.
- **Tool versions.** The script pins jscpd (`npx --yes jscpd@5.4.0`), honours `$SWIFTLINT` for a specific SwiftLint binary, and falls back to `python3 -m lizard` when no `lizard` is on PATH. The CI workflow installs the portable SwiftLint 0.65.1 release and `lizard==1.24.1` via pip, so CI numbers are comparable with the ones recorded here. Locally, check `swiftlint version` and `lizard --version` before comparing numbers.

## Visual regression baseline

Not captured yet. The launcher window (window ID found with `CGWindowListCopyWindowInfo`, default size 760 × 520 pt) is created hidden at launch, and opening it requires clicking the menu-bar item. `screencapture -l<windowID>` also needs the Screen Recording permission for the calling terminal, which cannot be checked without triggering the permission prompt. `docs/vrt/launcher-window.png` is therefore not present.
