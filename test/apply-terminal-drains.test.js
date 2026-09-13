import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// Every distinct terminal branch of `applyProc.onFinishedWith` must still
// drain the queue (Service.qml:840 onward): success, the unreadable-answer
// refusal, the shared exit-!==-0 branch (exit 3 here — exit 6 shares this
// same call site and would not be an independent proof; see below), the
// delete id-mismatch refusal, delete success, the unreadable-delete refusal,
// and a plain (non-`dueToday`) capture's create success each return through
// their own `root.drainApply()`. A branch that stops before that call leaves
// whatever is queued behind it stuck: no error, no completion, Pending
// forever — the exact failure a stranded queue looks like from the Pane.
//
// Review (Critical 2) caught that exit 3 and exit 6 both reach
// Service.qml:889 through the shared `code !== 0 || tooLarge` branch, so
// testing both proved the same call site twice while three other call sites
// (delete success, the unreadable-delete answer, and a plain create success)
// had no coverage anywhere. Exit 3 stays as this branch's one representative
// scenario; the other slot goes to a genuinely distinct site instead.
//
// One harness (`apply-terminal-drains.qml`) and one fake, reused across
// scenarios: the first Apply's `list` field tells the fake which branch to
// drive it into, a second ordinary Apply is queued right behind it, and the
// proof is that the second's fake actually runs — the queue kept moving.
// `Service.qml:845` (`sent === null`), `:861` (the epoch-drift discard) and
// `:945` (a chained capture's `set_due` success) are each covered
// separately — see the header of `apply-terminal-drains.qml` for why.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-terminal-drains: no `qs` on PATH — skipping the QML harness");
}

// The first Apply's `list` field selects the scenario; `L1` is what the
// second, ordinary Apply always sends, so its own invocation is unambiguous
// in the log regardless of which scenario ran before it.
function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/apply-terminal-drains.test.js.
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
        list=$(printf '%s' "$body" | grep -o '"list":"[^"]*"' | cut -d'"' -f4)
        printf 'apply %s\\n' "$list" >> "${logPath}"
        case "$list" in
          scn-success)
            printf '{"entry":{"id":"entry-first","list":"scn-success","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
            exit 0
            ;;
          scn-unreadable)
            printf 'not json at all\\n'
            exit 0
            ;;
          scn-exit3)
            printf '{"error":{"kind":"auth_expired","message":"fake: no grant"}}\\n' >&2
            exit 3
            ;;
          scn-delete-mismatch)
            printf '{"deleted":{"id":"wrong-id","list":"wrong-list"}}\\n'
            exit 0
            ;;
          scn-delete-success)
            printf '{"deleted":{"id":"task-first","list":"scn-delete-success"}}\\n'
            exit 0
            ;;
          scn-delete-unreadable)
            printf '{}\\n'
            exit 0
            ;;
          scn-create-success)
            printf '{"entry":{"id":"entry-created","list":"scn-create-success","parent":null,"title":"A captured task","display_title":"A captured task","type":"task","has_notes":false,"due":null,"status":"needsAction","completed_at":null,"position":"01"}}\\n'
            exit 0
            ;;
          L1)
            printf '{"entry":{"id":"entry-second","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"completed","completed_at":"2026-09-13T00:00:00Z","position":"01"}}\\n'
            exit 0
            ;;
          *)
            echo '{"error":{"kind":"usage","message":"fake: unknown scenario"}}' >&2
            exit 2
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

function terminalDrains(firstOp, firstList) {
  return runHarness("apply-terminal-drains.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: {
        OXIDONE_HARNESS_BIN: binary,
        OXIDONE_HARNESS_FIRST_OP: firstOp,
        OXIDONE_HARNESS_FIRST_LIST: firstList,
      },
    };
  });
}

// Every case shares the same drain proof: the harness only ever reports once
// both Applies are done, so reaching `report.reason === "drained"` at all —
// rather than the ceiling's timeout — already means the second one ran. The
// explicit log check on top of that rules out the harness having reported
// "drained" for some other reason (there isn't one here, but the check costs
// nothing and matches the other guards' style).
const scenarios = [
  {
    name: "success",
    op: "complete",
    list: "scn-success",
    check: (report) => {
      expect(report.firstError).toBe("");
      expect(report.firstPending).toBe(false);
    },
  },
  {
    name: "the unreadable-answer refusal",
    op: "complete",
    list: "scn-unreadable",
    check: (report) => {
      expect(report.firstError).toBe("the change did not go through");
      expect(report.firstPending).toBe(false);
    },
  },
  {
    name: "exit 3",
    op: "complete",
    list: "scn-exit3",
    check: (report) => {
      expect(report.state).toBe("auth-needed");
      expect(report.firstError).toBe("oxidone is not authorized any more");
    },
  },
  {
    name: "the delete id-mismatch refusal",
    op: "delete",
    list: "scn-delete-mismatch",
    check: (report) => {
      expect(report.firstError).toBe("the change did not go through");
    },
  },
  {
    name: "delete success",
    op: "delete",
    list: "scn-delete-success",
    check: (report) => {
      // The row is gone rather than erred — there is nothing left to carry
      // a message on.
      expect(report.firstError).toBe("");
      expect(report.firstPending).toBe(false);
    },
  },
  {
    name: "the unreadable-delete refusal",
    op: "delete",
    list: "scn-delete-unreadable",
    check: (report) => {
      expect(report.firstError).toBe("the change did not go through");
    },
  },
  {
    name: "a plain create success",
    op: "capture",
    list: "scn-create-success",
    check: (report) => {
      // The capture settled (its record removed) rather than left Pending
      // or carrying a failure message.
      expect(report.firstCaptureSettled).toBe(true);
    },
  },
];

for (const scenario of scenarios) {
  test.skipIf(quickshell === null)(
    `a queued Apply behind ${scenario.name} still runs`,
    () => {
      const { report, ran } = terminalDrains(scenario.op, scenario.list);

      expect(report.reason).toBe("drained");
      // The proof: the second Apply's real invocation actually happened.
      expect(ran).toContain("apply L1");
      expect(report.secondPending).toBe(false);

      scenario.check(report);
    },
    30000,
  );
}
