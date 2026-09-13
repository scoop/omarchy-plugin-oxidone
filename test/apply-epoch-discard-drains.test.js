import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The epoch-drift discard's own `drainApply()` call (Service.qml:861) must
// itself release what is queued behind it — not merely be present. Review
// caught that `apply-epoch-binary-swap.test.js` cannot prove this: `versionOk`
// is false there for the whole scenario, so drainApply's own `!versionOk`
// check (Service.qml:476) blocks line 861 before it ever does anything,
// making it a no-op that a deletion would not fail. This scenario instead
// lets the new binary's version check pass *before* the old binary's
// still-in-flight Apply answers, so `applyEpoch !== epoch` and
// `versionOk === true` are both true at once — the only way line 861 gets a
// real job to do.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-epoch-discard-drains: no `qs` on PATH — skipping the QML harness");
}

// The first binary: answers `--version` and `json today` at once, and holds
// its one `json apply` call open behind a marker file until released.
function firstBinary(aEnteredPath, aReleasePath) {
  return `#!/bin/bash
# Written by test/apply-epoch-discard-drains.test.js.
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
        touch "${aEnteredPath}"
        until [ -f "${aReleasePath}" ]; do sleep 0.02; done
        printf '{"entry":{"id":"task-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

// The second (replacement) binary: answers its own version check at once —
// nothing holds it back, since this scenario's whole point is that it must
// pass *before* the first binary's Apply is released. Every `json apply` it
// gets is logged and answered at once.
function secondBinary(logPath) {
  return `#!/bin/bash
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
        printf 'apply %s\\n' "$task" >> "${logPath}"
        printf '{"entry":{"id":"%s","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}\\n' "$task" | tr -d '\\n'
        printf '}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function epochDiscardDrains() {
  return runHarness("apply-epoch-discard-drains.qml", (dir, log) => {
    const first = join(dir, "oxidone-first");
    const second = join(dir, "oxidone-second");
    const aEntered = join(dir, "a-entered");
    const aRelease = join(dir, "a-release");
    return {
      binaries: {
        "oxidone-first": firstBinary(aEntered, aRelease),
        "oxidone-second": secondBinary(log),
      },
      env: {
        OXIDONE_HARNESS_FIRST: first,
        OXIDONE_HARNESS_SECOND: second,
        OXIDONE_HARNESS_A_ENTERED: aEntered,
        OXIDONE_HARNESS_A_RELEASE: aRelease,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "the epoch-drift discard's own drainApply() releases what is queued behind it",
  () => {
    const { report, ran } = epochDiscardDrains();

    expect(report.reason).toBe("drained");
    expect(report.versionOk).toBe(true);

    // The two behind task-1 ran for real, against the new binary, in order —
    // and nothing else was in a position to start them: versionProc's own
    // release call already found task-1 still in flight and no-opped.
    expect(ran).toEqual(["apply task-2", "apply task-3"]);
  },
  30000,
);
