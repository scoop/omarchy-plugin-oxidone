import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The Today generation guard: an Apply that folds its Echo while a `json
// today` read is in flight must not have that Echo overwritten by that
// read's older answer, AND the discard branch must still run the poll
// clock's bookkeeping afterwards (Service.qml:145, `todayApplyGeneration`;
// the discard itself lives in `todayProc.onFinishedWith`). Exercised through
// the real Service under a real Quickshell, the same way as
// service-version-gate.test.js — see test/qml/fold-during-today-poll.qml for
// why this needs three `json today` calls, not two, and why nothing here is
// a timing guess.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("fold-during-today-poll: no `qs` on PATH — skipping the QML harness");
}

// Call 1 answers `json today` at once, giving the Service a Snapshot to fold
// into. Call 2 deliberately fails (exit 4), driving `state` to `stale` and
// `consecutiveFailures` to 1 — a known bad baseline the bookkeeping proof
// needs, since answering plainly here would leave those fields already at
// their "good" values before the race even starts, and the proof would pass
// whether or not the discard branch's tail ever ran. Call 3 and every call
// after it is the slow, stale read the guard exists for: it marks its own
// start with a file the harness's QML waits on, and instead of a fixed
// sleep, waits on the Apply's own completion marker before answering — so
// nothing about the race's timing is a guess. `json apply` always answers
// with the entry completed and marks its own completion; the slow
// `json today` always answers with that same entry still `needsAction` — the
// stale, pre-fold answer the guard must discard.
function fakeBinary(logPath, counterPath, startedPath, donePath, applyDonePath) {
  return `#!/bin/bash
# Written by test/fold-during-today-poll.test.js. Logs every invocation.
printf '%s\\n' "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    case "\${2:-}" in
      today)
        count=0
        [[ -f "${counterPath}" ]] && count=$(cat "${counterPath}")
        count=$((count + 1))
        echo "$count" > "${counterPath}"
        if [[ "$count" -eq 2 ]]; then
          printf '{"error":{"kind":"network","message":"fake: forced failure"}}\\n' >&2
          exit 4
        fi
        if [[ "$count" -ge 3 ]]; then
          touch "${startedPath}"
          until [ -f "${applyDonePath}" ]; do sleep 0.02; done
        fi
        printf '{"today":"2026-09-13","entries":[{"id":"entry-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
        if [[ "$count" -ge 3 ]]; then
          touch "${donePath}"
        fi
        exit 0
        ;;
      apply)
        cat >/dev/null
        touch "${applyDonePath}"
        printf '{"entry":{"id":"entry-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function foldDuringTodayPoll() {
  return runHarness("fold-during-today-poll.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const counter = join(dir, "today-count");
    const started = join(dir, "today-started");
    const done = join(dir, "today-done");
    const applyDone = join(dir, "apply-done");
    return {
      binaries: {
        oxidone: fakeBinary(log, counter, started, done, applyDone),
      },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_STARTED: started,
        OXIDONE_HARNESS_DONE: done,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "a completed Echo survives a stale Today read that was already in flight, and the poll clock keeps running",
  () => {
    const { report, ran } = foldDuringTodayPoll();

    // The race actually happened: three Today reads (success, forced
    // failure, then the stale slow one) around exactly one Apply.
    expect(ran.filter((line) => line === "json today")).toHaveLength(3);
    expect(ran.filter((line) => line === "json apply")).toHaveLength(1);

    // 1. The fold survived: the Echo, not the stale poll's answer.
    expect(report.status).toBe("completed");
    // 2. `outstanding` reflects the Echo, not the discarded (needsAction)
    // answer.
    expect(report.outstanding).toBe(0);
    // 3. The discard branch still ran its bookkeeping through to
    // `scheduleNext(0)` rather than stopping at the `console.warn`. Proven
    // by moving `state`/`consecutiveFailures` to a known bad baseline (the
    // forced failure) *before* the race, then checking they were moved back
    // — `state` and `consecutiveFailures` returning to their success values
    // and `lastSuccess` advancing past the pre-race baseline is only
    // possible if the code past the discard's `console.warn` actually ran.
    // `state`, `lastSuccess` and `consecutiveFailures` sit on that same
    // straight-line, branch-free run as `scheduleNext(0)` itself, so this
    // shows the branch was not short-circuited — it does not observe
    // `scheduleNext(0)` (or the timer it (re)arms) directly.
    expect(report.state).toBe("ok");
    expect(report.consecutiveFailures).toBe(0);
    expect(report.lastSuccess).toBeGreaterThan(report.lastSuccessBeforeRace);
  },
  30000,
);
