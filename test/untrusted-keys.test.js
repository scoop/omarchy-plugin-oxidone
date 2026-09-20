import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The Service's id-keyed maps, exercised through the real Service under a real
// Quickshell. An Entry id is a string oxidone printed; `applyErrors` is read by
// the Pane as `applyErrors[row.id] !== undefined`, so on a plain object an id
// of `constructor` or `__proto__` answers for a row nothing has failed on.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.

if (quickshell === null) {
  console.warn("untrusted-keys: no `qs` on PATH — skipping the QML harness");
}

function fakeBinary(logPath) {
  return `#!/bin/bash
# Written by test/untrusted-keys.test.js.
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

function probe() {
  return runHarness("untrusted-keys.qml", (dir, log) => {
    const binary = join(dir, "oxidone");
    return {
      binaries: { oxidone: fakeBinary(log) },
      env: { OXIDONE_HARNESS_BIN: binary },
    };
  });
}

test.skipIf(quickshell === null)(
  "an Entry id off Object.prototype names no failure, and names its own",
  () => {
    const { report } = probe();
    expect(report.reason).toBe("probed");

    // A row whose id is one of these has nothing wrong with it, and must read
    // that way — even with another row's failure already in the map.
    expect(report.findings.constructorKey).toBe(true);
    expect(report.findings.protoKey).toBe(true);
    expect(report.findings.toStringKey).toBe(true);
    expect(report.findings.pendingConstructorKey).toBe(true);
    expect(report.findings.capturesConstructorKey).toBe(true);

    // The other direction: such an id is still a key like any other.
    expect(report.findings.constructorCarriesItsOwn).toBe(true);
    expect(report.findings.constructorClears).toBe(true);
    expect(report.findings.realOneUntouched).toBe(true);
    expect(report.findings.realOneStillThere).toBe(true);
  },
  30000,
);
