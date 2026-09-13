import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
  existsSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Drives a QML harness under a real `qs`, the reusable half of what
// `service-version-gate.test.js` proved out first (PR #10): only `qs`, run
// offscreen against the real `Service.qml`, can answer a question about QML
// binding order, and every scenario needs the same temp-dir assembly, fake
// binaries and `HARNESS {json}` parsing to ask one. What differs between
// scenarios is which harness `.qml` drives the Service and what its fakes do
// — that stays with each test file.

const repo = join(import.meta.dir, "..");

// The harness runs the Service under quickshell, which is always present on
// the machine this plugin runs on and never on a stock CI runner. Failing
// there would leave CI permanently red over something it cannot install, so
// every scenario skips instead — loudly, with its own `console.warn`, since
// this module has no test of its own to warn from.
export const quickshell = Bun.which("qs");

/**
 * Runs one QML harness and reports what it saw.
 *
 * `harnessFile` names a file already in `test/qml/`. It is copied into a
 * fresh temp config folder alongside symlinks to `Service.qml`,
 * `BoundedProcess.qml` and `src/` — symlinks that live only for this one run:
 * `qs` refuses a QML import that resolves outside the folder it was given,
 * and the marketplace validator refuses a symlink anywhere in a plugin, so
 * neither objection applies to a folder assembled fresh here and removed in
 * `finally`, never committed.
 *
 * `build(dir, log)` is the scenario. It gets the temp dir and a conventional
 * log path inside it — fakes are expected to append one line per invocation
 * (`"<label> <args>"`) there, the convention `service-version-gate.test.js`'s
 * fakes follow — and returns `{ binaries, env }`:
 *   - `binaries`: `{ filename: scriptBody }`. Each is written under `dir`,
 *     executable, never inside the installable tree.
 *   - `env`: merged into `qs`'s environment on top of `QT_QPA_PLATFORM:
 *     "offscreen"`. Typically the paths the scenario just chose for its own
 *     binaries, plus any marker or counter files its fakes coordinate
 *     through — the scenario computes all of these itself with `join(dir,
 *     …)`, since it already holds `dir`.
 *
 * Returns `{ report, ran }`:
 *   - `report`: the parsed `HARNESS {json}` line the harness prints before
 *     `Qt.exit`ing.
 *   - `ran`: the log, one invocation per line, or `[]` if no fake ever wrote
 *     one.
 */
export function runHarness(harnessFile, build) {
  const dir = mkdtempSync(join(tmpdir(), "oxidone-harness-"));
  try {
    const config = join(dir, "config");
    mkdirSync(config);
    for (const name of ["Service.qml", "BoundedProcess.qml", "src"]) {
      symlinkSync(join(repo, name), join(config, name));
    }
    copyFileSync(join(repo, "test", "qml", harnessFile), join(config, harnessFile));

    const log = join(dir, "exec.log");
    const { binaries, env } = build(dir, log);
    for (const [name, body] of Object.entries(binaries || {})) {
      writeFileSync(join(dir, name), body, { mode: 0o755 });
    }

    // The harness exits itself; `timeout` is only here so a wedged qs cannot
    // hold the suite open.
    const run = Bun.spawnSync(["timeout", "45", "qs", "-p", join(config, harnessFile)], {
      env: {
        ...process.env,
        QT_QPA_PLATFORM: "offscreen",
        ...env,
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    // qs prefixes and colours its log lines; the JSON after the marker is clean.
    const output = run.stdout.toString() + run.stderr.toString();
    const reported = /HARNESS (\{.*\})/.exec(output);
    if (!reported) {
      throw new Error("the harness reported nothing (is `qs` installed?):\n" + output);
    }
    return {
      report: JSON.parse(reported[1]),
      ran: existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : [],
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
