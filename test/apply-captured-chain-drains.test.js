import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The `chain === "captured"` success branch (Service.qml:945 — the second
// half of a Today capture) must still drain the queue. Not covered by
// `apply-terminal-drains.test.js`: reaching this branch needs a real
// `create` → chained `set_due`, and the queued Apply behind it has to be
// enqueued only once that chained `set_due` is genuinely in flight — any
// earlier and it would run ahead of the chain (on the `create` step's own
// drain instead), proving the wrong call site.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-captured-chain-drains: no `qs` on PATH — skipping the QML harness");
}

// Tells `create` from the chained `set_due` by the `op` field on stdin —
// `create` answers at once, `set_due` holds open behind a marker file. Every
// call is logged.
function fakeBinary(logPath, setDueEnteredPath, setDueReleasePath) {
  return `#!/bin/bash
# Written by test/apply-captured-chain-drains.test.js.
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
        printf 'apply %s\\n' "$op" >> "${logPath}"
        case "$op" in
          create)
            printf '{"entry":{"id":"echo-created","list":"L1","parent":null,"title":"Dated capture","display_title":"Dated capture","type":"task","has_notes":false,"due":null,"status":"needsAction","completed_at":null,"position":"01"}}\\n'
            exit 0
            ;;
          set_due)
            touch "${setDueEnteredPath}"
            until [ -f "${setDueReleasePath}" ]; do sleep 0.02; done
            printf '{"entry":{"id":"echo-created","list":"L1","parent":null,"title":"Dated capture","display_title":"Dated capture","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}}\\n'
            exit 0
            ;;
          complete)
            printf '{"entry":{"id":"task-third","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function capturedChainDrains() {
  return runHarness("apply-captured-chain-drains.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    const setDueEntered = join(dir, "set-due-entered");
    const setDueRelease = join(dir, "set-due-release");
    return {
      binaries: { oxidone: fakeBinary(log, setDueEntered, setDueRelease) },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_SET_DUE_ENTERED: setDueEntered,
        OXIDONE_HARNESS_SET_DUE_RELEASE: setDueRelease,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "a queued Apply behind a captured chain's set_due success still runs",
  () => {
    const { report, ran } = capturedChainDrains();

    expect(report.reason).toBe("drained");
    expect(report.captureSettled).toBe(true);

    // All three real invocations happened, in the order the chain and the
    // independent third Apply actually ran in.
    expect(ran).toEqual(["apply create", "apply set_due", "apply complete"]);
  },
  30000,
);
