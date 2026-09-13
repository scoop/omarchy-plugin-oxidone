import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// Issue #5: a second Apply enqueued against a row that already has one must
// not stop that row rendering as Pending. `applyPending` used to be a map
// written at enqueue and deleted by the answering handler, and `drainApply()`
// never re-wrote it — so the moment the first Apply was answered, the flag
// went and the second ran its whole flight with the row reading normal. Not a
// gap: `Pane.qml` also has `enabled: !entrySurface.pending`, so the row was
// interactive again mid-write and would take a third op.
//
// This is a binding question — whether the Pane's `applyPending[row.id] ===
// true` still holds while the queue moves underneath it — so it is asked of a
// real `qs` running the real `Service.qml`, the way the other queue
// invariants are. See `apply-pending-across-queue.qml` for the three
// observations and why each is taken where it is.
//
// The pure half of the answer — which keys the set contains, given a queue,
// an in-flight entry and a date request — is `Apply.pendingSet`, covered in
// `apply.test.js` without any of this machinery.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-pending-across-queue: no `qs` on PATH — skipping the QML harness");
}

// The first Apply is answered at once. The second announces itself and then
// blocks until the harness releases it, so Pending can be sampled from a turn
// of the event loop that none of the Service's own handlers ran in.
function fakeBinary(logPath, counterPath, enteredSecond, releaseSecond) {
  return `#!/bin/bash
# Written by test/apply-pending-across-queue.test.js.
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
      apply)
        body=$(cat)
        op=$(printf '%s' "$body" | grep -o '"op":"[^"]*"' | cut -d'"' -f4)
        n=0
        [[ -f "${counterPath}" ]] && n=$(cat "${counterPath}")
        n=$((n + 1))
        echo "$n" > "${counterPath}"
        printf 'enter %s %s\\n' "$n" "$op" >> "${logPath}"
        if [[ "$n" == "2" ]]; then
          touch "${enteredSecond}"
          until [ -f "${releaseSecond}" ]; do sleep 0.02; done
        fi
        printf 'exit %s %s\\n' "$n" "$op" >> "${logPath}"
        printf '{"entry":{"id":"task-dup","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-14","status":"needsAction","completed_at":null,"position":"01"}}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function pendingAcrossQueue() {
  return runHarness("apply-pending-across-queue.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const counter = join(dir, "apply-count");
    const enteredSecond = join(dir, "entered-2");
    const releaseSecond = join(dir, "release-2");
    return {
      binaries: { oxidone: fakeBinary(log, counter, enteredSecond, releaseSecond) },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_ENTERED_SECOND: enteredSecond,
        OXIDONE_HARNESS_RELEASE_SECOND: releaseSecond,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "a row with a second Apply queued against it stays Pending until the last Echo",
  () => {
    const { report, ran } = pendingAcrossQueue();

    expect(report.reason).toBe("drained");
    // Both really ran, in order, and the second was genuinely held open
    // rather than racing past the samples.
    expect(ran).toEqual([
      "enter 1 complete",
      "exit 1 complete",
      "enter 2 migrate",
      "exit 2 migrate",
    ]);

    // The defect itself: the row must never leave the Pending set while an
    // Apply naming it is still queued or in flight. Answering the first one
    // used to do exactly that.
    expect(report.clearedEarly).toBe(false);
    // And the row really does read Pending while the second is in flight —
    // sampled from a turn of the event loop the Service is not on, which is
    // the reading the Pane gets.
    expect(report.pendingWhileSecondInFlight).toBe(true);
    // Held, not stuck: the row is free again once the queue is empty.
    expect(report.pendingAfterDrain).toBe(false);

    expect(report.queueLength).toBe(0);
    expect(report.currentNull).toBe(true);
  },
  30000,
);
