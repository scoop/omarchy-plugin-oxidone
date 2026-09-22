import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// `applyErrors` inside a service the shell keeps loaded for its whole life.
// `captures` already has `captureFailureMax`; this is the same ceiling on the
// other store, exercised through the real Service under a real Quickshell.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("apply-error-bound: no `qs` on PATH — skipping the QML harness");
}

function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/apply-error-bound.test.js.
printf '%s\\n' "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    if [[ \${2:-} == today ]]; then
      printf '{"today":"2026-09-20","entries":[]}\\n'
      exit 0
    fi
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function bound() {
  return runHarness("apply-error-bound.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "failure messages stop at the ceiling, keeping the newest",
  () => {
    const { report } = bound();
    expect(report.reason).toBe("probed");

    // Twelve rows failed; five messages are kept, not twelve.
    expect(report.findings.max).toBe(5);
    expect(report.findings.keptCount).toBe(5);
    expect(report.findings.kept).toEqual(["t11", "t7", "t8", "t9", "t10"].sort());

    // The oldest went; the newest stayed. The order kept beside the map is the
    // same length as the map, so it cannot grow behind it either.
    expect(report.findings.oldestGone).toBe(true);
    expect(report.findings.newestKept).toBe(true);
    expect(report.findings.orderLength).toBe(5);
  },
  30000,
);
