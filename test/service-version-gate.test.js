import { test, expect } from "bun:test";
import { join } from "node:path";
import { runHarness, quickshell } from "./qml-harness.js";

// The version gate, exercised through the real Service under a real Quickshell.
//
// `src/version.js` can only say what a version string means; whether the binary
// that answered is the one we were told to ask is a question about QML binding
// order, and nothing short of running the component can answer it. So this
// drives Service.qml under `qs` with two fake binaries and reads back which of
// them was asked what.
//
// Offscreen, so it needs no Wayland session and can run anywhere `qs` can.
// The temp-dir assembly, fake-binary writing and `HARNESS` parsing live in
// `test/qml-harness.js`, shared with every other QML-driven test; this file
// keeps only the scenario — the two versions, the swap, and what each proves.

if (quickshell === null) {
  console.warn("service-version-gate: no `qs` on PATH — skipping the QML harness");
}

// Enough of an Entry to be the answer to `json today`: the id is what the test
// reads back, and the rest is shaped like oxidone's so the parser is exercised
// rather than tiptoed around.
function fakeBinary(label, version, entryId, logPath) {
  return `#!/bin/bash
# Written by test/service-version-gate.test.js. Logs every invocation, so the
# test can see which binary was asked for a version and which was read from.
printf '%s %s\\n' "${label}" "$*" >> "${logPath}"
case "\${1:-}" in
  --version)
    echo "oxidone ${version}"
    exit 0
    ;;
  json)
    if [[ \${2:-} == today ]]; then
      printf '{"today":"2026-09-13","entries":[{"id":"${entryId}","list":"L1","parent":null,"title":"A task","display_title":"A task","type":"task","has_notes":false,"due":"2026-09-13","status":"needsAction","completed_at":null,"position":"01"}]}\\n'
      exit 0
    fi
    ;;
esac
echo '{"error":{"kind":"usage","message":"fake: unexpected argument"}}' >&2
exit 2
`;
}

// Starts the Service on a binary reporting `firstVersion`, waits until that one
// has been vetted and read from, then points binaryPath at a second binary
// reporting `secondVersion`. Answers with what the Service ended up believing
// and the log of what actually ran.
function swapBinary(firstVersion, secondVersion) {
  return runHarness("harness.qml", (dir, log) => {
    const first = join(dir, "oxidone-first");
    const second = join(dir, "oxidone-second");
    return {
      binaries: {
        "oxidone-first": fakeBinary("first", firstVersion, "entry-first", log),
        "oxidone-second": fakeBinary("second", secondVersion, "entry-second", log),
      },
      env: {
        OXIDONE_HARNESS_FIRST: first,
        OXIDONE_HARNESS_SECOND: second,
      },
    };
  });
}

test.skipIf(quickshell === null)(
  "the re-check after a path change is answered by the new binary, not the previous one",
  () => {
    const { report, ran } = swapBinary("1.2.0", "1.1.0");

    // The heart of it: exactly one version check ever ran against the binary we
    // moved away from. A second one is the defect — the re-check for the
    // replacement, answered by its predecessor.
    expect(ran.filter((line) => line === "first --version")).toHaveLength(1);

    // The replacement was asked, it is below the floor, and the gate says so.
    expect(ran).toContain("second --version");
    expect(report.state).toBe("unusable");
    expect(report.versionOk).toBe(false);

    // And nothing was read from it: a binary that fails the gate is not one we
    // then go and talk to.
    expect(ran).not.toContain("second json today");
  },
  60000,
);

test.skipIf(quickshell === null)(
  "a usable replacement is vetted on its own path and then polled",
  () => {
    const { report, ran } = swapBinary("1.2.0", "1.2.0");

    expect(ran.filter((line) => line === "first --version")).toHaveLength(1);

    // Vetted first, read second — the order the gate exists to impose.
    const second = ran.filter((line) => line.startsWith("second "));
    expect(second[0]).toBe("second --version");
    expect(second).toContain("second json today");

    // The Snapshot is the replacement's own answer.
    expect(report.state).toBe("ok");
    expect(report.versionOk).toBe(true);
    expect(report.entry).toBe("entry-second");
  },
  60000,
);
