import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The Today generation guard: an Apply that folds its Echo while a `json
// today` read is in flight must not have that Echo overwritten by that
// read's older answer (Service.qml:145, `todayApplyGeneration`; the discard
// itself lives in `todayProc.onFinishedWith`). Exercised through the real
// Service under a real Quickshell, the same way as
// service-version-gate.test.js — see test/qml/fold-during-today-poll.qml for
// the shape of the race and why two shell loops, not a guess at Service's
// internals, decide when the Apply fires and when the result is read back.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("fold-during-today-poll: no `qs` on PATH — skipping the QML harness");
}

// `json today`'s first call answers at once, giving the Service a Snapshot
// to fold into; every call after that is the slow read the guard exists
// for, marking its own start and end with files the harness's QML waits on
// instead of a timing guess. `json apply` always answers with the entry
// completed; the slow `json today` always answers with that same entry
// still `needsAction` — the stale, pre-fold answer the guard must discard.
function fakeBinary(logPath, counterPath, startedPath, donePath) {
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
        if [[ "$count" -ge 2 ]]; then
          touch "${startedPath}"
          sleep 2
        fi
        printf '{"today":"2026-09-13","entries":[{"id":"entry-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
        if [[ "$count" -ge 2 ]]; then
          touch "${donePath}"
        fi
        exit 0
        ;;
      apply)
        cat >/dev/null
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
    return {
      binaries: {
        oxidone: fakeBinary(log, counter, started, done),
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
  "a completed Echo survives a stale Today read that was already in flight",
  () => {
    const { report, ran } = foldDuringTodayPoll();

    // The race actually happened: two Today reads (fast, then the stale
    // slow one) around exactly one Apply.
    expect(ran.filter((line) => line === "json today")).toHaveLength(2);
    expect(ran.filter((line) => line === "json apply")).toHaveLength(1);

    // 1. The fold survived: the Echo, not the stale poll's answer.
    expect(report.status).toBe("completed");
    // 2. `outstanding` reflects the Echo, not the discarded (needsAction)
    // answer.
    expect(report.outstanding).toBe(0);
    // 3. The poll clock still ran the discard path through to the end:
    // `state`, `lastSuccess` and `consecutiveFailures` are set on the same
    // straight-line run as `scheduleNext(0)`, with no branch between them,
    // so all three landing is the closest observable proxy for it having
    // been reached rather than short-circuited on the discard.
    expect(report.state).toBe("ok");
    expect(report.consecutiveFailures).toBe(0);
    expect(report.lastSuccess).toBeGreaterThan(0);
  },
  30000,
);
