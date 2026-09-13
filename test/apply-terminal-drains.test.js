import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// Every terminal branch of `applyProc.onFinishedWith` must still drain the
// queue (Service.qml:840 onward): success, the unreadable-answer refusal,
// exit 3, exit 6, and the delete id-mismatch refusal each return through
// `root.drainApply()`. A branch that stops before that call leaves whatever
// is queued behind it stuck: no error, no completion, Pending forever — the
// exact failure a stranded queue looks like from the Pane.
//
// One harness (`apply-terminal-drains.qml`) and one fake, reused across five
// scenarios: the first Apply's `list` field tells the fake which branch to
// drive it into, a second ordinary Apply is queued right behind it, and the
// proof is that the second's fake actually runs — the queue kept moving.
// The epoch-drift discard branch is proven separately, as part of
// `apply-epoch-binary-swap.test.js`, which already has to hold an Apply
// mid-flight while `epoch` moves out from under it; adding a queued
// follow-up there and re-deriving the same "still drains" proof here would
// be the sixth near-identical harness the brief warns against.
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
          scn-exit6)
            printf '{"error":{"kind":"not_found","message":"fake: gone"}}\\n' >&2
            exit 6
            ;;
          scn-delete-mismatch)
            printf '{"deleted":{"id":"wrong-id","list":"wrong-list"}}\\n'
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
    name: "exit 6",
    op: "complete",
    list: "scn-exit6",
    check: (report) => {
      // A row op's exit 6 removes the row instead of leaving a message on
      // it — there is no row left to carry one.
      expect(report.firstError).toBe("");
      expect(report.firstPending).toBe(false);
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
