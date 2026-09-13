import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The bounded retry (Service.qml:754, `listStaleDiscards > 3`): a binary
// that keeps answering for the wrong list must stop being retried after 3
// discards, not spin forever against something that will never agree with
// what was asked. Exercised through the real Service under a real
// Quickshell.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("list-stale-discard-bound: no `qs` on PATH — skipping the QML harness");
}

// Always answers `json tasks --list` for a list nobody asked for — the
// binary this guard exists for.
function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/list-stale-discard-bound.test.js.
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
        printf 'tasks\\n' >> "${logPath}"
        printf '{"list":"the-wrong-list","entries":[]}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function staleDiscardBound() {
  return runHarness("list-stale-discard-bound.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "a binary that keeps naming the wrong list is retried 3 times, then given up on",
  () => {
    const { report, ran } = staleDiscardBound();

    expect(report.reason).toBe("gave-up");

    // One initial request plus exactly 3 retries — never a 5th.
    expect(ran).toHaveLength(4);
    expect(report.listStaleDiscards).toBe(4);

    // Never once agreed with what was asked, so the Snapshot was never set.
    expect(report.listPayloadIsNull).toBe(true);
  },
  30000,
);
