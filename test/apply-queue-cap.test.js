import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The queue cap: `applyQueueMax` is 32 (Service.qml:97), checked in `applyOp`
// against `applyQueueDepth` (queued entries plus the one in flight, if any).
// The 33rd Apply queued past that must be refused with its row's error set,
// and the 32 that were accepted must still drain to completion — a refusal
// at the cap must not itself stop the drain. Exercised through the real
// Service under a real Quickshell, the same way as the generation guards.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-queue-cap: no `qs` on PATH — skipping the QML harness");
}

// Every `json apply` call is answered the same way regardless of which task
// it named: the cap guard does not care what the write was, only how many
// there were. Logs each invocation so the test can count real drains.
function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/apply-queue-cap.test.js. Logs every invocation.
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
      apply)
        cat >/dev/null
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

function queueCap() {
  return runHarness("apply-queue-cap.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "the 33rd Apply is refused at the cap, and the 32 accepted still drain",
  () => {
    const { report, ran } = queueCap();

    // Exactly the 32 accepted Applies really ran — not 33, and not fewer
    // (which would mean the drain stalled after the refusal).
    expect(ran.filter((line) => line === "json apply")).toHaveLength(32);

    // The 33rd's row carries the cap's own message, not a fold that
    // silently ignored it.
    expect(report.capError).toBe("too many changes at once");

    // And the queue this refusal happened alongside still drained to
    // completion: nothing left queued, nothing stuck in flight.
    expect(report.queueLength).toBe(0);
    expect(report.currentNull).toBe(true);
  },
  30000,
);
