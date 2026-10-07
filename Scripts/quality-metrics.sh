#!/bin/bash
#
# quality-metrics.sh — numeric quality metrics for Claude Profiles (macOS).
#
# Produces dist/metrics/metrics.json plus a Markdown table (dist/metrics/metrics.md) so the
# numbers can be pasted into docs/QUALITY.md / PLAN.md. Every metric is numeric on purpose:
# a metric that needs a human judgement call ends up paging a human every time.
#
# Sections (some can be skipped so CI can run a cheap subset):
#   lint      SwiftLint with every opt-in rule enabled (.swiftlint.yml) -> warning/error counts
#   compiler  clean `swift build -c release`                            -> compiler warning count
#   ccn       lizard                                                    -> cyclomatic complexity
#   dup       jscpd (via npx)                                           -> duplicated-line percentage
#   mutation  muter (muter.conf.yml, 3 operators)                       -> mutation score
#   perf      hyperfine / ps / top / leaks                              -> launch, idle RSS/CPU, leaks
#
# Usage:
#   Scripts/quality-metrics.sh [--skip-compiler] [--skip-mutation] [--skip-perf] [--check-thresholds]
#
#   --check-thresholds  compare lint / ccn / dup with Scripts/quality-thresholds.env and exit 1
#                       if any value is above its ceiling (ratchet used by CI).
#
# WARNING: the perf section terminates every running "ClaudeProfilesApp" process (including
# an installed copy in /Applications) because the launcher holds a single-instance lock.
# Restart your installed copy afterwards.
#
# Requires: swiftlint, python3 (+ lizard), npx (node); for mutation: muter; for perf: hyperfine.
#
# Tool versions are pinned so CI and local numbers are comparable (the ratchet ceilings
# depend on them): SwiftLint 0.65.1, lizard 1.24.1, jscpd 5.4.0. A tool already on PATH is
# used first (local machines); otherwise the pinned fallback is used. $SWIFTLINT may point
# at a specific swiftlint binary (for example the portable 0.65.1 release).
set -euo pipefail

# Homebrew and pipx/uv tool locations are not on PATH in non-login shells.
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/metrics"
mkdir -p "$OUT"
cd "$ROOT"

SKIP_COMPILER=0
SKIP_MUTATION=0
SKIP_PERF=0
CHECK_THRESHOLDS=0
for arg in "$@"; do
    case "$arg" in
        --skip-compiler) SKIP_COMPILER=1 ;;
        --skip-mutation) SKIP_MUTATION=1 ;;
        --skip-perf) SKIP_PERF=1 ;;
        --check-thresholds) CHECK_THRESHOLDS=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- Tool resolution ----------------------------------------------------------
SWIFTLINT="${SWIFTLINT:-swiftlint}"
JSCPD=(npx --yes jscpd@5.4.0)
# `python3 -m lizard` avoids depending on where pip placed the lizard entry-point script.
if command -v lizard >/dev/null 2>&1; then
    LIZARD=(lizard)
else
    LIZARD=(python3 -m lizard)
fi

# Reads one key from a JSON file; prints "null" when the file is missing or unreadable so a
# failed tool shows up as a missing number instead of aborting the whole report.
# The expression ($2) is evaluated with eval; it is always a literal written in this script,
# never data from a tool's output, so no untrusted input reaches eval.
json_get() {
    python3 - "$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
    print(eval(expr, {"d": data}))
except Exception:
    print("null")
PY
}

# ---------------------------------------------------------------------------
# 1. Static analysis: SwiftLint with every opt-in rule enabled.
# SwiftLint exits non-zero when it finds errors; that is a result, not a script failure.
# stderr goes to a log so configuration problems (e.g. unknown rules) can be inspected.
# ---------------------------------------------------------------------------
echo "== swiftlint"
"$SWIFTLINT" lint --quiet --reporter json > "$OUT/swiftlint.json" 2> "$OUT/swiftlint.log" || true
LINT_WARNINGS=$(json_get "$OUT/swiftlint.json" "sum(1 for i in d if i['severity']=='Warning')")
LINT_ERRORS=$(json_get "$OUT/swiftlint.json" "sum(1 for i in d if i['severity']=='Error')")
echo "swiftlint warnings=$LINT_WARNINGS errors=$LINT_ERRORS"

# ---------------------------------------------------------------------------
# 2. Compiler warnings on a clean release build.
# A fresh scratch path guarantees every file is recompiled; otherwise cached modules hide
# their warnings. Identical warning lines are de-duplicated because SwiftPM can repeat them.
# ---------------------------------------------------------------------------
COMPILER_WARNINGS="null"
if [ "$SKIP_COMPILER" -eq 0 ]; then
    echo "== compiler warnings"
    COMPILER_LOG="$OUT/swift-build.log"
    rm -rf "$OUT/scratch"
    swift build -c release --scratch-path "$OUT/scratch" > "$COMPILER_LOG" 2>&1 || { tail -20 "$COMPILER_LOG"; exit 1; }
    COMPILER_WARNINGS=$( (grep "warning:" "$COMPILER_LOG" || true) | sort -u | wc -l | tr -d ' ')
    echo "compiler warnings=$COMPILER_WARNINGS"
fi

# ---------------------------------------------------------------------------
# 3. Cyclomatic complexity (lizard). Threshold 10 follows lizard's default -C.
# ---------------------------------------------------------------------------
echo "== lizard"
"${LIZARD[@]}" Sources --csv > "$OUT/lizard.csv"
python3 - "$OUT/lizard.csv" "$OUT/lizard.json" <<'PY'
import csv, json, sys
rows = list(csv.reader(open(sys.argv[1])))
# lizard --csv has no header. Columns: NLOC, CCN, token, PARAM, length, location, file,
# function, long_name, start, end.
ccn = [int(r[1]) for r in rows]
nloc = [int(r[0]) for r in rows]
out = {
    "functions": len(ccn),
    "nloc_total": sum(nloc),
    "ccn_avg": round(sum(ccn) / len(ccn), 2) if ccn else 0,
    "ccn_max": max(ccn) if ccn else 0,
    "functions_over_10": sum(1 for c in ccn if c > 10),
    "functions_over_15": sum(1 for c in ccn if c > 15),
    "worst": sorted(
        [{"ccn": int(r[1]), "function": r[7], "file": r[6]} for r in rows],
        key=lambda x: -x["ccn"])[:5],
}
json.dump(out, open(sys.argv[2], "w"), indent=2)
print(json.dumps({k: v for k, v in out.items() if k != "worst"}))
PY

# ---------------------------------------------------------------------------
# 4. Duplication (jscpd). min-tokens 50 is jscpd's default; we report the duplicated-line
# percentage it computes. The previous report is removed so a failed run cannot be
# mistaken for a fresh one.
# ---------------------------------------------------------------------------
echo "== jscpd"
rm -rf "$OUT/jscpd"
"${JSCPD[@]}" Sources --format swift --reporters json --output "$OUT/jscpd" --silent > "$OUT/jscpd.log" 2>&1 || true
DUP_PERCENT=$(json_get "$OUT/jscpd/jscpd-report.json" "round(d['statistics']['total']['percentage'], 2)")
DUP_CLONES=$(json_get "$OUT/jscpd/jscpd-report.json" "d['statistics']['total']['clones']")
echo "duplication percent=$DUP_PERCENT clones=$DUP_CLONES"

# ---------------------------------------------------------------------------
# 5. Mutation testing (muter). Uses muter.conf.yml in the repo root (Core sources only).
# Slow (minutes); skipped in CI with --skip-mutation.
#
# - SwapTernary is not used: muter 16 rewrites `c ? x is A : x is B` into code that does
#   not compile (`x is A is B`), which aborts the whole run with "Build failed".
#   The other three operators are passed explicitly instead.
# - muter runs inside a sibling copy "<repo>_mutated" and resolves --output relative to
#   it, so the output path must be absolute. The copy (with its own .build) is removed
#   afterwards so it does not linger next to the repository.
# ---------------------------------------------------------------------------
MUTATION_SCORE="null"
if [ "$SKIP_MUTATION" -eq 0 ]; then
    echo "== muter"
    rm -f "$OUT/muter.json"
    muter run --skip-coverage --skip-update-check \
        --operators RelationalOperatorReplacement RemoveSideEffects ChangeLogicalConnector \
        --format json --output "$OUT/muter.json" > "$OUT/muter.log" 2>&1 || true
    if [ -d "${ROOT}_mutated" ]; then
        # SwiftPM checkouts inside the copy are read-only; without u+w `rm -r` asks for
        # confirmation per file on a terminal and the run hangs.
        chmod -R u+w "${ROOT}_mutated"
        rm -r "${ROOT}_mutated" < /dev/null
    fi
    MUTATION_SCORE=$(json_get "$OUT/muter.json" "d.get('globalMutationScore', d.get('mutationScore', 'null'))")
    echo "mutation score=$MUTATION_SCORE"
fi

# ---------------------------------------------------------------------------
# 6. Runtime performance of the built app (dist/Claude Profiles.app must exist).
#   launch_ms : hyperfine wall time from exec until LaunchServices registers the app
#   rss_mb    : resident set after 20 s idle
#   cpu_pct   : average %CPU of the last 2 of 3 `top` samples while idle (the first
#               sample has no previous interval and is always meaningless)
#   rss_growth: RSS 120 s after launch minus RSS at 20 s while idle (leak substitute)
#   leaks     : leaked allocations reported by `leaks`, or null when leaks cannot attach
#               (always null for ad-hoc signed builds)
# ---------------------------------------------------------------------------
LAUNCH_MS="null"; RSS_MB="null"; CPU_PCT="null"; LEAKS="null"; RSS_GROWTH_MB="null"
if [ "$SKIP_PERF" -eq 0 ]; then
    echo "== perf"
    APP="$ROOT/dist/Claude Profiles.app"
    BIN="$APP/Contents/MacOS/ClaudeProfilesApp"
    [ -x "$BIN" ] || { echo "build the app first (Scripts/build-app.sh)"; exit 1; }
    # Stop any other launcher instance: the app holds a single-instance lock and a second
    # copy would exit immediately, which would make every measurement meaningless.
    pkill -x ClaudeProfilesApp 2>/dev/null || true
    sleep 1
    BUNDLE_ID="io.github.un907.claudeprofiles"

    # Prints the PID of every LaunchServices registration for our bundle ID.
    # `lsappinfo info -app <bundle id>` prints nothing on current macOS, so registrations
    # are looked up by ASN via `lsappinfo find`.
    cat > "$OUT/registered-pids.sh" <<SCRIPT
#!/bin/bash
for asn in \$(lsappinfo find bundleid=$BUNDLE_ID); do
    lsappinfo info -only pid "\$asn" | grep -Eo 'pid = [0-9]+' | grep -Eo '[0-9]+'
done
SCRIPT
    chmod +x "$OUT/registered-pids.sh"

    # Measured command: exec -> registered in LaunchServices under *this* PID -> kill -> wait.
    # Matching the PID (not just the bundle ID) prevents a stale registration left by the
    # previous run from stopping the timer early. Bounded to 10 s so a crash fails the run.
    cat > "$OUT/launch-once.sh" <<SCRIPT
#!/bin/bash
"$BIN" >/dev/null 2>&1 &
pid=\$!
for _ in \$(seq 200); do
    if "$OUT/registered-pids.sh" | grep -qx "\$pid"; then
        kill \$pid; wait \$pid 2>/dev/null || true; exit 0
    fi
    sleep 0.05
done
kill \$pid 2>/dev/null || true
exit 1
SCRIPT
    chmod +x "$OUT/launch-once.sh"

    # Run before every timed run and warmup (hyperfine --prepare): wait until the previous
    # instance is fully gone, both as a process and as a LaunchServices registration.
    # Bounded to 10 s.
    cat > "$OUT/wait-gone.sh" <<SCRIPT
#!/bin/bash
for _ in \$(seq 200); do
    if ! pgrep -x ClaudeProfilesApp >/dev/null && [ -z "\$("$OUT/registered-pids.sh")" ]; then
        exit 0
    fi
    sleep 0.05
done
exit 1
SCRIPT
    chmod +x "$OUT/wait-gone.sh"

    hyperfine --warmup 2 --runs 10 --prepare "$OUT/wait-gone.sh" \
        --export-json "$OUT/hyperfine.json" "$OUT/launch-once.sh" >/dev/null
    LAUNCH_MS=$(json_get "$OUT/hyperfine.json" "round(d['results'][0]['mean']*1000, 1)")
    "$OUT/wait-gone.sh"

    "$BIN" >/dev/null 2>&1 &
    PID=$!
    START=$SECONDS
    sleep 20
    RSS_KB_20=$(ps -o rss= -p "$PID" | tr -d ' ')
    RSS_MB=$(awk -v k="$RSS_KB_20" 'BEGIN {printf "%.1f", k/1024}')
    CPU_PCT=$(top -l 3 -s 2 -pid "$PID" -stats cpu | grep -E '^[0-9. ]+$' | tail -2 | awk '{s+=$1} END {printf "%.2f", s/NR}')
    # An ad-hoc signed app without the get-task-allow entitlement is "not debuggable":
    # leaks then only sees read-only memory and its count is not trustworthy, so it is
    # recorded as null and idle RSS growth is used as the leak signal instead.
    LEAKS_OUT=$(leaks "$PID" 2>&1 || true)
    echo "$LEAKS_OUT" > "$OUT/leaks.log"
    if ! grep -q "not debuggable" <<<"$LEAKS_OUT"; then
        LEAKS=$(grep -Eo '[0-9]+ leaks? for' <<<"$LEAKS_OUT" | grep -Eo '^[0-9]+' || echo null)
    fi
    # Second RSS sample 120 s after launch, regardless of how long top/leaks took.
    sleep $((120 - (SECONDS - START)))
    RSS_KB_120=$(ps -o rss= -p "$PID" | tr -d ' ')
    RSS_GROWTH_MB=$(awk -v a="$RSS_KB_20" -v b="$RSS_KB_120" 'BEGIN {printf "%.1f", (b-a)/1024}')
    kill "$PID"; wait "$PID" 2>/dev/null || true
    echo "launch_ms=$LAUNCH_MS rss_mb=$RSS_MB cpu_pct=$CPU_PCT rss_growth_mb=$RSS_GROWTH_MB leaks=$LEAKS"
fi

# ---------------------------------------------------------------------------
# Summary (metrics.json + metrics.md). "null" means skipped or not measurable.
# ---------------------------------------------------------------------------
python3 - "$OUT" "$LINT_WARNINGS" "$LINT_ERRORS" "$COMPILER_WARNINGS" "$DUP_PERCENT" "$DUP_CLONES" "$MUTATION_SCORE" "$LAUNCH_MS" "$RSS_MB" "$CPU_PCT" "$LEAKS" "$RSS_GROWTH_MB" <<'PY'
import json, sys, datetime
out = sys.argv[1]
lizard = json.load(open(f"{out}/lizard.json"))
def num(v, cast=float):
    return None if v in ("null", "None", "") else cast(float(v))
m = {
    "measured_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "swiftlint_warnings": num(sys.argv[2], int),
    "swiftlint_errors": num(sys.argv[3], int),
    "compiler_warnings": num(sys.argv[4], int),
    "ccn_avg": lizard["ccn_avg"],
    "ccn_max": lizard["ccn_max"],
    "functions_over_ccn_10": lizard["functions_over_10"],
    "functions_total": lizard["functions"],
    "duplication_percent": num(sys.argv[5]),
    "duplication_clones": num(sys.argv[6], int),
    "mutation_score_percent": num(sys.argv[7]),
    "launch_ms": num(sys.argv[8]),
    "idle_rss_mb": num(sys.argv[9]),
    "idle_cpu_percent": num(sys.argv[10]),
    "idle_rss_growth_mb": num(sys.argv[12]),
    "leaks": num(sys.argv[11], int),
}
json.dump(m, open(f"{out}/metrics.json", "w"), indent=2, ensure_ascii=False)
rows = "\n".join(f"| {k} | {v} |" for k, v in m.items())
open(f"{out}/metrics.md", "w").write(f"| metric | value |\n|---|---|\n{rows}\n")
print(open(f"{out}/metrics.md").read())
PY

# ---------------------------------------------------------------------------
# Ratchet: fail when lint / ccn / dup got worse than the recorded ceilings.
# Ceilings live in Scripts/quality-thresholds.env and are lowered as the code improves.
# Comparison is done in Python because the duplication value is a float.
# ---------------------------------------------------------------------------
if [ "$CHECK_THRESHOLDS" -eq 1 ]; then
    echo "== thresholds"
    # shellcheck source=/dev/null
    source "$ROOT/Scripts/quality-thresholds.env"
    python3 - "$OUT/metrics.json" "$MAX_SWIFTLINT_WARNINGS" "$MAX_FUNCTIONS_OVER_CCN_10" "$MAX_DUPLICATION_PERCENT" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
checks = [
    ("swiftlint_warnings", float(sys.argv[2])),
    ("functions_over_ccn_10", float(sys.argv[3])),
    ("duplication_percent", float(sys.argv[4])),
]
failed = False
for key, ceiling in checks:
    value = m.get(key)
    # A missing value means the tool failed; treat it as a failure, not a pass.
    ok = value is not None and float(value) <= ceiling
    print(f"{'OK  ' if ok else 'FAIL'} {key}={value} (max {ceiling:g})")
    failed |= not ok
sys.exit(1 if failed else 0)
PY
fi
