import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// One scenario proving three guards at once — see
// test/qml/apply-epoch-binary-swap.qml for why they share a harness:
//
//   - `applyEpoch` vs `epoch` (Service.qml:141): an Apply answered by a
//     binary we swapped away from must not fold — "nothing folds".
//   - The queue held by `!versionOk` (Service.qml:476): the two Applies
//     still queued behind the swapped one must not run until the new
//     binary is vetted.
//   - `versionProc`'s success path (Service.qml:636) is what releases that
//     hold — nothing else does.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-epoch-binary-swap: no `qs` on PATH — skipping the QML harness");
}

// The first binary: answers `json today` at once (giving the Snapshot a
// `task-1` entry to not-fold into), and holds its one `json apply` call open
// behind a marker file until the harness releases it.
function firstBinary(aEnteredPath, aReleasePath) {
  return `#!/bin/bash
# Written by test/apply-epoch-binary-swap.test.js.
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    case "\${2:-}" in
      today)
        printf '{"today":"2026-09-13","entries":[{"id":"task-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
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

// The second (replacement) binary: its own version check is held open
// behind a marker file, so the harness can confirm the hold before letting
// it pass. Once vetted, every `json apply` it gets answers at once, and each
// is logged so the test can see both held Applies really ran, in order.
function secondBinary(logPath, bVersionReleasePath) {
  return `#!/bin/bash
case "\${1:-}" in
  --version)
    until [ -f "${bVersionReleasePath}" ]; do sleep 0.02; done
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    case "\${2:-}" in
      today)
        printf '{"today":"2026-09-13","entries":[{"id":"task-1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
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

function epochBinarySwap() {
  return runHarness("apply-epoch-binary-swap.qml", (dir, log) => {
    const first = join(dir, "oxidone-first");
    const second = join(dir, "oxidone-second");
    const aEntered = join(dir, "a-entered");
    const aRelease = join(dir, "a-release");
    const bVersionRelease = join(dir, "b-version-release");
    return {
      binaries: {
        "oxidone-first": firstBinary(aEntered, aRelease),
        "oxidone-second": secondBinary(log, bVersionRelease),
      },
      env: {
        OXIDONE_HARNESS_FIRST: first,
        OXIDONE_HARNESS_SECOND: second,
        OXIDONE_HARNESS_A_ENTERED: aEntered,
        OXIDONE_HARNESS_A_RELEASE: aRelease,
        OXIDONE_HARNESS_B_VERSION_RELEASE: bVersionRelease,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "a binary swapped mid-Apply folds nothing, holds the queue, and releases it once vetted",
  () => {
    const { report, ran } = epochBinarySwap();

    // The two Applies behind the swapped one were genuinely queued (not
    // already running) at the moment of the swap.
    expect(report.queueLengthAtSwap).toBe(2);

    // While held: the new binary was not yet vetted, and the two behind
    // `task-1` were still sitting in the queue untouched (not already
    // running against it) at the moment this was checked — captured live,
    // before the release below could let anything move.
    expect(report.versionOkWhileHeld).toBe(false);
    expect(report.queueLengthWhileHeld).toBe(2);

    // The epoch-drift discard: `task-1`'s Echo — the one thing that would
    // prove a fold happened — must not have landed. The row is left
    // `needsAction`, not `completed`, and the discard says so on the row.
    expect(report.task1StatusWhileHeld).toBe("needsAction");
    expect(report.task1ErrorWhileHeld).not.toBe("");
    expect(report.finalTask1Status).toBe("needsAction");

    // Released: once the new binary passed its version check, the two held
    // Applies ran for real, against it, in the order they were queued.
    expect(ran).toEqual(["apply task-2", "apply task-3"]);
    expect(report.versionOk).toBe(true);
    expect(report.reason).toBe("drained");
  },
  30000,
);
