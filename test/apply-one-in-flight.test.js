import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// One Apply in flight at a time (Service.qml:472, `drainApply`): it starts
// nothing new while `applyCurrent !== null` or `applyProc.running`. This is
// the property the whole ordering argument for the queue rests on — the cap,
// the terminal-branch drain and the version-gate hold all assume it.
//
// Five Applies are queued in one burst; the fake holds each real invocation
// open behind a marker file until the harness explicitly releases it, so the
// log is a genuine trace of when each invocation actually started and ended.
//
// The real failure mode here is not two processes overlapping — `applyProc`
// is one `Process` instance, and its own `start()` no-ops while `running` is
// already true, so a broken `drainApply()` guard cannot make a second real
// child spawn while the first is still up. What it actually does, proven by
// hand-tracing a scratch mutation that dropped the guard down to just the
// empty-queue check: `applyCurrent` and `stdinPayload` get silently
// reassigned to a later entry while the earlier one is still in flight, so
// the earlier entry is dropped — never sent, never erred, Pending forever —
// while only the last overwrite's payload ever reaches the one process that
// does run. That is what the per-task presence and length checks below
// actually catch. The overlap check stays too, as a cheap invariant worth
// keeping now that the log has real timing in it, but it is not what proves
// the guard: it never fires under the mutation above, since only one real
// "enter" ever happens.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-one-in-flight: no `qs` on PATH — skipping the QML harness");
}

function fakeBinary(logPath, counterPath, enteredPrefix, releasePrefix) {
  return `#!/bin/bash
# Written by test/apply-one-in-flight.test.js.
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
        task=$(printf '%s' "$body" | grep -o '"task":"[^"]*"' | cut -d'"' -f4)
        n=0
        [[ -f "${counterPath}" ]] && n=$(cat "${counterPath}")
        n=$((n + 1))
        echo "$n" > "${counterPath}"
        printf 'enter %s\\n' "$task" >> "${logPath}"
        touch "${enteredPrefix}$n"
        until [ -f "${releasePrefix}$n" ]; do sleep 0.02; done
        printf 'exit %s\\n' "$task" >> "${logPath}"
        printf '{"entry":{"id":"entry-x","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function oneInFlight() {
  return runHarness("apply-one-in-flight.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const counter = join(dir, "apply-count");
    const enteredPrefix = join(dir, "entered-");
    const releasePrefix = join(dir, "release-");
    return {
      binaries: { oxidone: fakeBinary(log, counter, enteredPrefix, releasePrefix) },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_ENTERED_PREFIX: enteredPrefix,
        OXIDONE_HARNESS_RELEASE_PREFIX: releasePrefix,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "five queued Applies never overlap, and each runs exactly once",
  () => {
    const { report, ran } = oneInFlight();

    // Every real invocation actually ran, none dropped or duplicated by a
    // bookkeeping mix-up: all five, each exactly once, on both sides.
    for (let i = 0; i < 5; i++) {
      expect(ran.filter((line) => line === `enter task-${i}`)).toHaveLength(1);
      expect(ran.filter((line) => line === `exit task-${i}`)).toHaveLength(1);
    }
    expect(ran).toHaveLength(10);

    // A cheap invariant, not the proof: no "enter" ever appears while a
    // previous "enter" is still missing its "exit". A broken guard here
    // does not trip this (see the header note) — it silently drops an
    // entry instead, which the per-task counts above and the exact-order
    // check below are what actually catch.
    let open = 0;
    for (const line of ran) {
      if (line.startsWith("enter ")) {
        expect(open).toBe(0);
        open += 1;
      } else if (line.startsWith("exit ")) {
        expect(open).toBe(1);
        open -= 1;
      }
    }
    expect(open).toBe(0);

    // FIFO: queued in task-0..task-4 order, so that is the order they ran in.
    expect(ran).toEqual([
      "enter task-0",
      "exit task-0",
      "enter task-1",
      "exit task-1",
      "enter task-2",
      "exit task-2",
      "enter task-3",
      "exit task-3",
      "enter task-4",
      "exit task-4",
    ]);

    expect(report.queueLength).toBe(0);
    expect(report.currentNull).toBe(true);
  },
  30000,
);
