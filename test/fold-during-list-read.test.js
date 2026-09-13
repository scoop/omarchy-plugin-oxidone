import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The List generation guard: an Apply that folds its Echo while a `json
// tasks --list` read is in flight must not have that Echo overwritten by
// that read's older answer (Service.qml:150, `tasksApplyGeneration`; the
// discard itself lives in `tasksProc.onFinishedWith`). This one matters more
// than its Today twin: there is no clock behind a List, so a row this guard
// failed to protect stays reverted until the scope changes or the pane
// reopens, not just for one poll cycle. Exercised through the real Service
// under a real Quickshell — see test/qml/fold-during-list-read.qml for the
// shape of the race.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("fold-during-list-read: no `qs` on PATH — skipping the QML harness");
}

// `json tasks --list`'s first call answers at once, giving the Service a
// listPayload to fold into; every call after that is the slow read the
// guard exists for, marking its own start with a file the harness's QML
// waits on and — instead of a fixed sleep — waiting on the Apply's own
// completion marker before marking its own end and answering, so nothing
// about this race's timing is a guess. `json today` is answered emptily so
// the ordinary poll Service.qml starts on its own doesn't clutter the log.
// `json apply` always answers with the entry completed and marks its own
// completion; the slow `json tasks --list` always answers with that same
// entry still `needsAction` — the stale, pre-fold answer the guard must
// discard.
function fakeBinary(logPath, counterPath, startedPath, donePath, applyDonePath) {
  return `#!/bin/bash
# Written by test/fold-during-list-read.test.js. Logs every invocation.
printf '%s\\n' "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    case "\${2:-}" in
      today)
        printf '{"today":"2026-09-13","entries":[]}\\n'
        exit 0
        ;;
      tasks)
        count=0
        [[ -f "${counterPath}" ]] && count=$(cat "${counterPath}")
        count=$((count + 1))
        echo "$count" > "${counterPath}"
        if [[ "$count" -ge 2 ]]; then
          touch "${startedPath}"
          until [ -f "${applyDonePath}" ]; do sleep 0.02; done
        fi
        printf '{"list":"L1","entries":[{"id":"entry-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
        if [[ "$count" -ge 2 ]]; then
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

function foldDuringListRead() {
  return runHarness("fold-during-list-read.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const counter = join(dir, "list-count");
    const started = join(dir, "list-started");
    const done = join(dir, "list-done");
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
  "a completed Echo survives a stale List read that was already in flight",
  () => {
    const { report, ran } = foldDuringListRead();

    // The race actually happened: two List reads (fast, then the stale slow
    // one) around exactly one Apply.
    expect(ran.filter((line) => line === "json tasks --list L1")).toHaveLength(2);
    expect(ran.filter((line) => line === "json apply")).toHaveLength(1);

    // listPayload keeps the folded Echo — the entry is still `completed`,
    // not reverted to the stale read's `needsAction`. With no clock behind
    // a List read, a guard failing here would stay wrong indefinitely
    // rather than for one poll cycle, which is why this one is asserted on
    // its own rather than folded into a three-part check like Today's.
    expect(report.status).toBe("completed");
  },
  30000,
);
