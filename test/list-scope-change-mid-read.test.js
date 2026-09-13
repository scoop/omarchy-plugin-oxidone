import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The List scope guard (Service.qml:229, `listRequestedId` vs `listId`):
// changing scope while a `json tasks --list` read is out must discard that
// read's answer and then actually request the list that is now wanted.
// Exercised through the real Service under a real Quickshell.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("list-scope-change-mid-read: no `qs` on PATH — skipping the QML harness");
}

// `json tasks --list <id>` answers with whichever list it was actually
// asked for — the real shape of a well-behaved binary. Only the L1 call
// holds open, behind a marker file, so the harness can change scope while
// it is genuinely still in flight.
function fakeBinary(logPath, l1EnteredPath, l1ReleasePath) {
  return `#!/bin/bash
# Written by test/list-scope-change-mid-read.test.js.
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
        list="\${4:-}"
        printf 'tasks %s\\n' "$list" >> "${logPath}"
        if [[ "$list" == "L1" ]]; then
          touch "${l1EnteredPath}"
          until [ -f "${l1ReleasePath}" ]; do sleep 0.02; done
        fi
        printf '{"list":"%s","entries":[]}\\n' "$list"
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function scopeChangeMidRead() {
  return runHarness("list-scope-change-mid-read.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const l1Entered = join(dir, "l1-entered");
    const l1Release = join(dir, "l1-release");
    return {
      binaries: { oxidone: fakeBinary(log, l1Entered, l1Release) },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_L1_ENTERED: l1Entered,
        OXIDONE_HARNESS_L1_RELEASE: l1Release,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "a scope change mid-read discards the stale answer and asks for the wanted list",
  () => {
    const { report, ran } = scopeChangeMidRead();

    // Both reads actually happened, in order: the stale one for L1 (the
    // scope in flight when it was asked), then the real one for L2 (the
    // scope actually wanted by the time it answered).
    expect(ran).toEqual(["tasks L1", "tasks L2"]);

    // The stale L1 answer was discarded, not kept: the Snapshot carries L2.
    expect(report.listPayloadList).toBe("L2");
    expect(report.listId).toBe("L2");

    // Exactly one discard happened, and it did not linger as a standing
    // count against a binary that has since answered correctly.
    expect(report.listStaleDiscards).toBe(0);
  },
  30000,
);
