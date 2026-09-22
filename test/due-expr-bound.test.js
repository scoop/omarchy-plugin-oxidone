import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// `oxidone json due <phrase>` is the only place this plugin passes a string as
// an argument, so the question worth proving is not what `Rows.isDueExpr`
// returns — `rows.test.js` has that — but whether a phrase it refuses really
// fails to reach `dueProc.command`. Only the running Service can answer that,
// so this reads a fake binary's own log of what it was invoked with.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("due-expr-bound: no `qs` on PATH — skipping the QML harness");
}

// Logs every invocation, and answers `json due` with a date so the valid
// phrase's chained `set_due` has something well-formed to go on with.
function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/due-expr-bound.test.js.
printf '%s\\n' "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    case "\${2:-}" in
      today)
        printf '{"today":"2026-09-20","entries":[]}\\n'
        exit 0
        ;;
      due)
        printf '{"due":"2026-09-17"}\\n'
        exit 0
        ;;
      apply)
        cat > /dev/null
        printf '{"results":[]}\\n'
        exit 0
        ;;
    esac
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function dueExprBound() {
  return runHarness("due-expr-bound.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "a date phrase that is too long or not plain never reaches argv, and `-3d` still does",
  () => {
    const { report, ran } = dueExprBound();
    expect(report.reason).toBe("asked");

    // Refused before the process, and said so on the row that asked.
    expect(report.longError).toBe("not a date phrase");
    expect(report.controlError).toBe("not a date phrase");

    // The one-at-a-time gate is downstream of the refusal, so a refused phrase
    // must not have consumed the slot: the valid phrase still went out clean.
    expect(report.validError).toBe("");

    const due = ran.filter((line) => line.startsWith("json due"));
    expect(due).toEqual(["json due -3d"]);
    // Nothing that was refused appears anywhere in what ran, under any verb.
    expect(ran.some((line) => line.includes("aaaaaaaa"))).toBe(false);
  },
  30000,
);
