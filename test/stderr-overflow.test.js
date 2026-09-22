import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// `BoundedProcess` stderr, exercised through the real Service under a real
// Quickshell: a child that writes past `maxErrBytes` is refused whole, the way
// stdout already was, rather than having its error envelope cut down to the cap
// and handed on as if it were complete.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("stderr-overflow: no `qs` on PATH — skipping the QML harness");
}

// A sound answer on stdout, 64 KiB on stderr, exit 0 — the combination that
// truncation would have let through untouched.
function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/stderr-overflow.test.js.
printf '%s\\n' "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone 1.2.0"
    exit 0
    ;;
  json)
    if [[ \${2:-} == today ]]; then
      printf '{"today":"2026-09-20","entries":[{"id":"t1","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-20","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
      for _ in $(seq 1 64); do
        head -c 1024 /dev/zero | tr '\\0' 'E' >&2
      done
      exit 0
    fi
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

function overflow() {
  return runHarness("stderr-overflow.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "a child whose stderr outgrows its ceiling is refused, not shortened",
  () => {
    const { report } = overflow();

    // Refused: the overflow reached the caller as `tooLarge`, which is what
    // sends the Service Stale instead of letting the answer land.
    expect(report.reason).toBe("refused");
    expect(report.payloadIsNull).toBe(true);
    expect(report.outstanding).toBe(0);
  },
  30000,
);
