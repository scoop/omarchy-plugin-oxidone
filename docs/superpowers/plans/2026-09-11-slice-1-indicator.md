# Slice 1: Indicator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bar Indicator that shows how much is outstanding in Today, polled from `oxidone json today`, absent when that count is zero.

**Architecture:** A `keepLoaded` Service owns a 5-minute poll; each poll is one short-lived, output-bounded `oxidone json today` process. Everything decidable is a pure function in `src/*.js` and unit-tested with `bun test`; the QML is a thin shell around it. No writes, no Pane, no persistence.

**Tech Stack:** Quickshell/QML (Qt 6), plain JavaScript for logic, `bun test`, eslint + prettier + husky + lint-staged.

**Spec:** `docs/superpowers/specs/2026-09-11-omarchy-plugin-oxidone.md`

## Global Constraints

- Plugin id is `scoop.oxidone`; the install directory name must equal it.
- Requires **oxidone >= 1.1.0** (`oxidone json` first shipped there; 1.0.0 prints a version and has no such subcommand).
- Style only from `qs.Commons.Color` and `qs.Commons.Style`, composed from `qs.Ui`. A literal hex colour, px radius or font size in plugin QML is a defect.
- `textFormat: Text.PlainText` on every `Text` that renders a string sourced from Google.
- Child processes: absolute-path argv arrays, `clearEnvironment: true` with an explicit minimal environment, producer-side output caps, an absolute deadline and TERM→KILL teardown. Never `StdioCollector`.
- Read deadline 30s. Poll interval default 300s, configurable 60–3600.
- JS modules are dual-mode: top-level `var`/`function` declarations for QML's `import "src/x.js" as X`, plus a guarded `if (typeof module !== "undefined") { module.exports = {…} }` tail for `bun test`.
- No `CLAUDE.md`, `AGENTS.md` or `.claude/` anywhere in the tree — `omarchy plugin add` copies the repo verbatim into a path coding agents auto-discover.

---

### Task 1: Repository scaffolding and manifest

**Files:**

- Create: `manifest.json`, `package.json`, `eslint.config.js`, `.prettierrc`, `.prettierignore`, `.gitignore`, `LICENSE`, `.husky/pre-commit`
- Modify (one-time, on adopting prettier): `CONTEXT.md`, `docs/superpowers/specs/2026-09-11-omarchy-plugin-oxidone.md` — emphasis markers only, no prose changes

**Interfaces:**

- Consumes: nothing.
- Produces: the manifest's `barWidget.defaults` keys `binaryPath` (string, `""`) and `pollIntervalSec` (integer, `300`), read by `Indicator.qml` in Task 7 via `setting(name, fallback)`.

- [ ] **Step 1: Write the manifest**

`manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "scoop.oxidone",
  "name": "oxidone",
  "version": "0.1.0",
  "author": "scoop",
  "description": "What is due today in Google Tasks, read through the oxidone CLI. The bar stays empty until something is.",
  "license": "MIT",
  "kinds": ["service", "bar-widget"],
  "keepLoaded": true,
  "entryPoints": {
    "service": "Service.qml",
    "barWidget": "Indicator.qml"
  },
  "barWidget": {
    "displayName": "oxidone",
    "description": "Tasks due today, via the oxidone CLI",
    "category": "Productivity",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": {
      "binaryPath": "",
      "pollIntervalSec": 300
    },
    "schema": [
      {
        "key": "binaryPath",
        "type": "path",
        "label": "oxidone binary",
        "defaultValue": "",
        "description": "Absolute path to the oxidone binary. Leave empty for ~/.local/bin/oxidone."
      },
      {
        "key": "pollIntervalSec",
        "type": "integer",
        "label": "Poll interval (seconds)",
        "min": 60,
        "max": 3600,
        "step": 60,
        "defaultValue": 300
      }
    ]
  }
}
```

The `overlay` kind and its `Pane.qml` entry point arrive in slice 2. Declaring a kind whose entry point does not exist fails validation.

- [ ] **Step 2: Write the tooling files**

`package.json`:

```json
{
  "name": "omarchy-plugin-oxidone",
  "version": "0.1.0",
  "private": true,
  "type": "commonjs",
  "scripts": {
    "test": "bun test",
    "lint": "eslint .",
    "format": "prettier --write ."
  },
  "devDependencies": {
    "eslint": "^9",
    "prettier": "^3",
    "husky": "^9",
    "lint-staged": "^16"
  },
  "lint-staged": {
    "*.{js,json,md}": "prettier --write",
    "*.js": "eslint --fix"
  }
}
```

`eslint.config.js`:

```js
module.exports = [
  {
    files: ["src/**/*.js", "test/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: { module: "writable", console: "readonly" },
    },
    rules: {
      eqeqeq: "error",
      "no-var": "off",
      "prefer-const": "off",
    },
  },
];
```

`no-var` and `prefer-const` are off deliberately: these files are loaded by QML's JavaScript engine as well as by bun, and `var` is the form that behaves identically in both.

`.prettierrc`:

```json
{
  "printWidth": 100,
  "tabWidth": 2,
  "semi": true,
  "trailingComma": "all"
}
```

`.gitignore`:

```
node_modules/
```

- [ ] **Step 3: Install and wire the hook**

```bash
bun install
bunx husky init
printf '%s\n' 'bunx lint-staged' > .husky/pre-commit
```

- [ ] **Step 4: Validate the manifest**

The validator refuses symlinks anywhere in a plugin folder, and `bun install`
fills `node_modules/.bin/` with them — so the working tree can never be
validated in place once dev dependencies exist. Validate what actually ships
instead: a clean export, which is the same tree Task 8 installs.

Add to `package.json`'s `scripts`:

```json
"validate": "rm -rf .validate && mkdir -p .validate && tar -cf - --exclude=.git --exclude=node_modules --exclude=.superpowers --exclude=docs --exclude=test --exclude=.husky --exclude=.validate . | tar -xf - -C .validate && /usr/share/omarchy/bin/omarchy-plugin-validate .validate && rm -rf .validate"
```

and `.validate/` to `.gitignore`.

Run: `bun run validate`
Expected: exits 0 with no findings. Check the exit status directly (`echo $?`
on the validator, not through a pipe — piping to `tail` reports the pager's
status, not the validator's). If it reports a missing entry point, that is
correct: `Service.qml` and `Indicator.qml` do not exist yet. Create both as
one-line placeholders (`import QtQuick` then `Item {}`) so validation passes,
and let Tasks 6 and 7 replace them.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold plugin, manifest and tooling"
```

---

### Task 2: `src/today.js` — read the CLI's answer into what the bar needs

**Files:**

- Create: `src/today.js`
- Test: `test/today.test.js`
- Modify: `eslint.config.js` — Task 1's config forces `sourceType: "commonjs"` on `test/**/*.js`, which cannot parse `import { test, expect } from "bun:test"`. Split it: `src/**/*.js` stays commonjs (QML's engine loads it), `test/**/*.js` becomes `sourceType: "module"`.

**Interfaces:**

- Consumes: nothing.
- Produces: `parseToday(stdout) -> payload`, `outstandingCount(payload) -> number`, `hasOverdue(payload) -> boolean`. `payload` is `{today: string, entries: Entry[]}`. Consumed by `Service.qml` (Task 6).

**Ruling (pre-flight):** the completed-today filter the spec calls for — `visibleEntries`, `isCompletedToday`, `localDateOf` — is deferred to slice 2. Slice 1's count is `needsAction`-only, so nothing here would use it, and an untested-in-anger filter sitting unused is exactly what YAGNI forbids. The oxidone#135 rationale moves with it.

- [ ] **Step 1: Write the failing tests**

`test/today.test.js`:

```js
import { test, expect } from "bun:test";
import { parseToday, outstandingCount, hasOverdue } from "../src/today.js";

const entry = (over) =>
  Object.assign(
    {
      id: "t1",
      list: "L",
      parent: null,
      title: "Thing",
      display_title: "Thing",
      type: "task",
      has_notes: false,
      due: "2026-07-20",
      status: "needsAction",
      completed_at: null,
      position: "00",
    },
    over,
  );

const payload = (entries) => ({ today: "2026-07-20", entries });

test("a well-formed answer parses to its date and entries", () => {
  const parsed = parseToday(JSON.stringify(payload([entry({})])));
  expect(parsed.today).toBe("2026-07-20");
  expect(parsed.entries.length).toBe(1);
});

test("an answer that is not an object is refused rather than guessed at", () => {
  expect(() => parseToday("[]")).toThrow();
  expect(() => parseToday('{"entries": []}')).toThrow();
  expect(() => parseToday('{"today": "2026-07-20"}')).toThrow();
});

test("the count is outstanding work, so a completed entry is not in it", () => {
  expect(outstandingCount(payload([entry({}), entry({ id: "t2", status: "completed" })]))).toBe(1);
});

test("an Event counts as work to come, a Note does not", () => {
  const entries = [entry({ type: "event" }), entry({ id: "t2", type: "note" })];
  expect(outstandingCount(payload(entries))).toBe(1);
});

test("overdue is outstanding and dated strictly before today", () => {
  expect(hasOverdue(payload([entry({})]))).toBe(false);
  expect(hasOverdue(payload([entry({ due: "2026-07-19" })]))).toBe(true);
  expect(hasOverdue(payload([entry({ due: "2026-07-19", status: "completed" })]))).toBe(false);
  expect(hasOverdue(payload([entry({ due: null })]))).toBe(false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test test/today.test.js`
Expected: FAIL — cannot resolve `../src/today.js`.

- [ ] **Step 3: Write the implementation**

`src/today.js`:

```js
// `oxidone json today` read into what the bar needs. Pure functions only — no
// QML, no I/O — so the test runner and the shell load the same file.
//
// Slice 1 counts only what is outstanding, so the CLI's status-blindness does
// not reach the bar: a completed entry is excluded by status whatever its date.
// The completed-today filter oxidone#135 calls for arrives with the Pane, which
// is the first surface that renders a Completed row at all.

function parseToday(stdout) {
  var payload = JSON.parse(stdout);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("today: expected an object");
  }
  if (typeof payload.today !== "string") {
    throw new Error("today: no `today` date");
  }
  if (!Array.isArray(payload.entries)) {
    throw new Error("today: no `entries` array");
  }
  return payload;
}

// The bar's number: outstanding work. An Event occupies the day as a Task does,
// so it counts; a Note is not work you finish, so it does not. This is the
// Due-load's rule, not the Completion meter's.
function outstandingCount(payload) {
  return payload.entries.filter(function (entry) {
    return entry.status === "needsAction" && entry.type !== "note";
  }).length;
}

// Anything still outstanding and dated strictly before today. Drives the
// urgent colour, and nothing else.
function hasOverdue(payload) {
  return payload.entries.some(function (entry) {
    return (
      entry.status === "needsAction" &&
      entry.type !== "note" &&
      typeof entry.due === "string" &&
      entry.due < payload.today
    );
  });
}

if (typeof module !== "undefined") {
  module.exports = {
    parseToday: parseToday,
    outstandingCount: outstandingCount,
    hasOverdue: hasOverdue,
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test test/today.test.js`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/today.js test/today.test.js
git commit -m "feat(today): read the CLI's answer into the bar's count"
```

---

### Task 3: `src/version.js` — the version gate

**Files:**

- Create: `src/version.js`
- Test: `test/version.test.js`

**Interfaces:**

- Consumes: nothing.
- Produces: `parseVersion(stdout) -> [major, minor, patch] | null`, `satisfies(version, floor) -> boolean`, and the constant `MINIMUM = [1, 1, 0]`. Consumed by `Service.qml` (Task 6).

- [ ] **Step 1: Write the failing tests**

`test/version.test.js`:

```js
import { test, expect } from "bun:test";
import { parseVersion, satisfies, MINIMUM } from "../src/version.js";

test("the version line oxidone prints parses to its parts", () => {
  expect(parseVersion("oxidone 1.1.0\n")).toEqual([1, 1, 0]);
});

test("anything that is not that line is refused rather than assumed current", () => {
  expect(parseVersion("")).toBe(null);
  expect(parseVersion("oxidone")).toBe(null);
  expect(parseVersion("some other tool 1.1.0")).toBe(null);
  expect(parseVersion("oxidone v1.1")).toBe(null);
});

test("the floor is 1.1.0, the release the json entry point shipped in", () => {
  expect(MINIMUM).toEqual([1, 1, 0]);
});

test("a version at or above the floor satisfies it", () => {
  expect(satisfies([1, 1, 0], MINIMUM)).toBe(true);
  expect(satisfies([1, 2, 0], MINIMUM)).toBe(true);
  expect(satisfies([2, 0, 0], MINIMUM)).toBe(true);
});

test("1.0.0 does not satisfy it, having no json subcommand at all", () => {
  expect(satisfies([1, 0, 0], MINIMUM)).toBe(false);
  expect(satisfies([0, 9, 9], MINIMUM)).toBe(false);
  expect(satisfies([1, 0, 99], MINIMUM)).toBe(false);
});

test("an unparseable version satisfies nothing", () => {
  expect(satisfies(null, MINIMUM)).toBe(false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test test/version.test.js`
Expected: FAIL — cannot resolve `../src/version.js`.

- [ ] **Step 3: Write the implementation**

`src/version.js`:

```js
// The version gate. `oxidone json` first shipped in 1.1.0; 1.0.0 prints a
// version perfectly happily and has no such subcommand, so "it runs and prints"
// is not evidence the contract is there.

/** The floor: the release the json entry point shipped in. */
var MINIMUM = [1, 1, 0];

// `oxidone --version` prints exactly `oxidone X.Y.Z`. Anything else — another
// tool on the configured path, a wrapper script, an error — is not a version.
function parseVersion(stdout) {
  var found = /^oxidone (\d+)\.(\d+)\.(\d+)\s*$/m.exec(String(stdout || ""));
  if (!found) {
    return null;
  }
  return [Number(found[1]), Number(found[2]), Number(found[3])];
}

function satisfies(version, floor) {
  if (!version) {
    return false;
  }
  for (var i = 0; i < 3; i++) {
    if (version[i] > floor[i]) {
      return true;
    }
    if (version[i] < floor[i]) {
      return false;
    }
  }
  return true;
}

if (typeof module !== "undefined") {
  module.exports = { MINIMUM: MINIMUM, parseVersion: parseVersion, satisfies: satisfies };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test test/version.test.js`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add src/version.js test/version.test.js
git commit -m "feat(version): gate on oxidone 1.1.0, the release json shipped in"
```

---

### Task 4: `src/state.js` — exit codes into bar states

**Files:**

- Create: `src/state.js`
- Test: `test/state.test.js`

**Interfaces:**

- Consumes: nothing.
- Produces: constants `OK`, `AUTH_NEEDED`, `STALE`, `UNUSABLE`; `stateForExit(code) -> string`; `nextDelaySeconds(code, intervalSeconds, failures) -> number`; `errorKindOf(stderr) -> string`. Consumed by `Service.qml` (Task 6).

- [ ] **Step 1: Write the failing tests**

`test/state.test.js`:

```js
import { test, expect } from "bun:test";
import {
  OK,
  AUTH_NEEDED,
  STALE,
  stateForExit,
  nextDelaySeconds,
  errorKindOf,
} from "../src/state.js";

test("a clean exit is a good answer", () => {
  expect(stateForExit(0)).toBe(OK);
});

test("exit 3 is the authorization states, and only those", () => {
  expect(stateForExit(3)).toBe(AUTH_NEEDED);
  expect(stateForExit(4)).toBe(STALE);
});

test("every other failure keeps the snapshot rather than nagging", () => {
  [1, 2, 4, 5, 6, 7].forEach((code) => expect(stateForExit(code)).toBe(STALE));
});

test("a good answer schedules the ordinary interval", () => {
  expect(nextDelaySeconds(0, 300, 0)).toBe(300);
});

test("a network failure backs off exponentially", () => {
  expect(nextDelaySeconds(4, 300, 0)).toBe(300);
  expect(nextDelaySeconds(4, 300, 1)).toBe(600);
  expect(nextDelaySeconds(4, 300, 2)).toBe(1200);
});

test("backoff stops at half an hour", () => {
  expect(nextDelaySeconds(4, 300, 9)).toBe(1800);
});

test("an exhausted quota waits an hour, nothing smaller can change it", () => {
  expect(nextDelaySeconds(5, 300, 0)).toBe(3600);
});

test("a missing grant does not back off — no request was made to fail", () => {
  expect(nextDelaySeconds(3, 300, 5)).toBe(300);
});

test("the error kind is lifted from the envelope for the log", () => {
  expect(errorKindOf('{"error":{"kind":"auth_expired","message":"…"}}')).toBe("auth_expired");
});

test("an envelope that is not one yields no kind rather than throwing", () => {
  expect(errorKindOf("segmentation fault")).toBe("");
  expect(errorKindOf("")).toBe("");
  expect(errorKindOf("{}")).toBe("");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test test/state.test.js`
Expected: FAIL — cannot resolve `../src/state.js`.

- [ ] **Step 3: Write the implementation**

`src/state.js`:

```js
// oxidone's exit codes turned into the states the bar can be in.
//
// The CLI's codes are documented in oxidone's docs/json-cli.md: 1 internal,
// 2 usage, 3 not_configured/auth_expired/token_store_failed, 4 network/
// rate_limited/pagination, 5 rejected/quota_exhausted, 6 not_found, 7 refused.
//
// The bar has far fewer states than that, deliberately. Five of those codes are
// indistinguishable to someone standing at a bar widget, and inventing a state
// per code would be a lot of QML for states nobody can act on.

/** A fresh answer arrived. */
var OK = "ok";
/** oxidone has no usable grant. Only the TUI can fix it. */
var AUTH_NEEDED = "auth-needed";
/** The last answer stands because a newer one could not be had. */
var STALE = "stale";
/** No usable oxidone at the configured path. */
var UNUSABLE = "unusable";

function stateForExit(code) {
  if (code === 0) {
    return OK;
  }
  // Exit 3 is the whole authorization family — no credentials configured, a
  // dead grant, or a token file that cannot be read. All three mean the same
  // thing to us: run the TUI.
  if (code === 3) {
    return AUTH_NEEDED;
  }
  // Everything else keeps the Snapshot. 1 and 2 are our own fault and get
  // logged; 5, 6 and 7 only reach a write, which slice 1 does not make.
  return STALE;
}

function nextDelaySeconds(code, intervalSeconds, failures) {
  if (code === 0) {
    return intervalSeconds;
  }
  // An exhausted daily quota cannot change inside a poll interval, and retrying
  // into it just spends the next day's allowance early.
  if (code === 5) {
    return 3600;
  }
  // Nothing was sent, so there is nothing to be gentle with — and a grant can
  // come back the moment the TUI is run.
  if (code === 3) {
    return intervalSeconds;
  }
  var doublings = Math.min(failures, 3);
  return Math.min(intervalSeconds * Math.pow(2, doublings), 1800);
}

// oxidone prints {"error":{"kind","message"}} on stderr. The kind is worth
// logging; the message is oxidone's to phrase and ours to stay out of.
function errorKindOf(stderr) {
  try {
    var body = JSON.parse(String(stderr || ""));
    if (body && body.error && typeof body.error.kind === "string") {
      return body.error.kind;
    }
  } catch (ignored) {
    // Not an envelope. A crash, a wrapper's noise, or nothing at all.
  }
  return "";
}

if (typeof module !== "undefined") {
  module.exports = {
    OK: OK,
    AUTH_NEEDED: AUTH_NEEDED,
    STALE: STALE,
    UNUSABLE: UNUSABLE,
    stateForExit: stateForExit,
    nextDelaySeconds: nextDelaySeconds,
    errorKindOf: errorKindOf,
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test`
Expected: PASS, all three files, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add src/state.js test/state.test.js
git commit -m "feat(state): map oxidone's exit codes onto the bar's states"
```

---

### Task 5: `BoundedProcess.qml` — a child that cannot outgrow its budget

**Files:**

- Create: `BoundedProcess.qml`

**Interfaces:**

- Consumes: nothing.
- Produces: a `Process` subclass with `property int maxBytes` (default 65536), `property int deadlineMs` (default 30000), and `signal finishedWith(string stdoutText, string stderrText, int code, bool tooLarge)`. Instantiated by `Service.qml` (Task 6), which sets `command` and calls `running = true`.

There is no unit-test harness for QML in this host — the shell is the runtime. The tested logic lives in `src/*.js`; this file is verified live in Task 8.

- [ ] **Step 1: Write the component**

`BoundedProcess.qml`:

```qml
import QtQuick
import Quickshell
import Quickshell.Io

// A child process whose output cannot outgrow a budget, whose environment is
// the one we chose rather than the one we inherited, and which cannot outlive
// its deadline.
//
// StdioCollector keeps everything the child writes and only then lets you
// measure it — by the time a length check runs the bytes are already in the
// shell's heap. This counts each chunk as it arrives, stops at the ceiling and
// kills the child rather than truncating: an answer that outgrew its budget is
// a refusal, not a value to salvage.
//
// The environment matters for the same reason the argv does. An inherited
// environment carries BASH_ENV, LD_PRELOAD and the proxy variables into every
// child, each of which lets another process running as this user decide what
// code runs or where a request goes. oxidone reads its config and token from
// under HOME and talks to Google over TLS; it needs nothing else from us.
Process {
    id: root

    /** Ceiling for everything the child writes to stdout, in characters. */
    property int maxBytes: 65536
    /** Ceiling for stderr. An error envelope is small; a crash dump is not. */
    property int maxErrBytes: 8192
    /** How long the child may run before it is taken down. */
    property int deadlineMs: 30000

    /** Emitted once per run, after the child has exited. */
    signal finishedWith(string stdoutText, string stderrText, int code, bool tooLarge)

    property string _out: ""
    property string _err: ""
    property bool _overflowed: false

    clearEnvironment: true
    environment: ({
            // Fixed, absolute and short: nothing here resolves through a
            // directory another process can prepend to.
            PATH: "/usr/bin:/bin",
            HOME: Quickshell.env("HOME"),
            // oxidone reads XDG_CONFIG_HOME for its config and token when set.
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME"),
            // Byte semantics, and dates that do not depend on the shell's locale.
            LC_ALL: "C",
        })

    onStarted: {
        _out = "";
        _err = "";
        _overflowed = false;
        deadlineTimer.restart();
    }

    stdout: SplitParser {
        // No marker: raw chunks. A line-delimited parser has to buffer until the
        // delimiter before it can hand anything over, so the ceiling would
        // arrive after the allocation it exists to prevent.
        splitMarker: ""
        onRead: function (chunk) {
            if (root._overflowed) {
                return;
            }
            if (root._out.length + chunk.length > root.maxBytes) {
                root._overflowed = true;
                root._out = "";
                root.signal(15);
                killTimer.restart();
                return;
            }
            root._out += chunk;
        }
    }

    stderr: SplitParser {
        splitMarker: ""
        onRead: function (chunk) {
            if (root._err.length >= root.maxErrBytes) {
                return;
            }
            root._err += chunk.slice(0, root.maxErrBytes - root._err.length);
        }
    }

    onExited: function (code) {
        deadlineTimer.stop();
        killTimer.stop();
        root.finishedWith(root._out, root._err, code, root._overflowed);
        root._out = "";
        root._err = "";
        root._overflowed = false;
    }

    // Declared as properties rather than children: Process has no default
    // property, so it cannot hold one.

    // A poll nobody is waiting on still does not get to run forever.
    property Timer deadlineTimer: Timer {
        interval: root.deadlineMs
        repeat: false
        onTriggered: {
            root.signal(15);
            killTimer.restart();
        }
    }

    // A child that ignores TERM does not get to keep running.
    property Timer killTimer: Timer {
        interval: 2000
        repeat: false
        onTriggered: root.signal(9)
    }
}
```

- [ ] **Step 2: Verify it loads**

Run: `omarchy-shell shell rescanPlugins && journalctl --user -u omarchy-shell -n 30 --no-pager | grep -i 'oxidone\|error' || true`
Expected: no QML syntax or type errors mentioning `BoundedProcess.qml`. A warning about the placeholder `Service.qml` is fine at this point.

- [ ] **Step 3: Commit**

```bash
git add BoundedProcess.qml
git commit -m "feat(process): bounded, deadlined child process with a chosen environment"
```

---

### Task 6: `Service.qml` — own the poll

**Files:**

- Modify: `Service.qml` (replacing the Task 1 placeholder)

**Interfaces:**

- Consumes: `src/today.js`, `src/version.js`, `src/state.js` (Tasks 2–4), `BoundedProcess.qml` (Task 5).
- Produces, for `Indicator.qml` (Task 7): `property string binaryPath`, `property int pollIntervalSec` (both written by the Indicator), and read-only `property int outstanding`, `property bool overdue`, `property string state`, `property double lastSuccess`. `refresh()` is the Service's own entry point, driven by its timer and its settings changing; no other component calls it.

- [ ] **Step 1: Write the service**

`Service.qml`:

```qml
import QtQuick
import Quickshell
import "src/today.js" as Today
import "src/state.js" as State
import "src/version.js" as Version

// Owns the poll and the state derived from it.
//
// Mounted for the life of the shell, because the Indicator's job is to be right
// when nobody is looking at it. The Indicator reads from here; it never runs
// oxidone itself.
//
// Every read is one short-lived process. There is no daemon and no connection
// to keep alive: a five-minute cadence does not justify supervising one, and a
// process that exits is a process that cannot leak.
Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null

    // Pushed down by the Indicator: the shell injects settings into bar widgets
    // only, never into a service.
    property string binaryPath: ""
    property int pollIntervalSec: 300

    // The Snapshot: the last good answer, and what the bar shows until a newer
    // one arrives. Held in memory only — the first poll lands seconds after the
    // shell starts, and a file written every five minutes would buy a few
    // seconds of cold-start accuracy for exactly the symlink and
    // predictable-path race surface that review scrutinises hardest.
    property int outstanding: 0
    property bool overdue: false

    // Starts silent, not alarmed. UNUSABLE would light the attention glyph for
    // the few hundred milliseconds before the first version check answers, and
    // a widget that cries wolf on every shell start is one you learn to ignore.
    // With no entries yet the Indicator is hidden either way.
    property string state: State.OK
    property double lastSuccess: 0
    property int consecutiveFailures: 0

    // Empty means "the default install location". Resolved once, here, so the
    // rest of the file can assume an absolute path.
    readonly property string resolvedBinary: binaryPath !== "" ? binaryPath : Quickshell.env("HOME") + "/.local/bin/oxidone"

    // A relative path would resolve against whatever directory the shell
    // happens to be in, which is not a decision this plugin gets to leave to
    // chance. Fail closed and say so.
    readonly property bool binaryLooksAbsolute: resolvedBinary.charAt(0) === "/"

    property bool versionChecked: false
    property bool versionOk: false

    function refresh() {
        if (!binaryLooksAbsolute) {
            root.state = State.UNUSABLE;
            console.warn("oxidone: configured path is not absolute:", resolvedBinary);
            return;
        }
        if (!versionChecked) {
            versionProc.running = true;
            return;
        }
        if (!versionOk) {
            root.state = State.UNUSABLE;
            return;
        }
        if (!todayProc.running) {
            todayProc.running = true;
        }
    }

    function scheduleNext(code) {
        pollTimer.interval = State.nextDelaySeconds(code, root.pollIntervalSec, root.consecutiveFailures) * 1000;
        pollTimer.restart();
    }

    // Re-check the binary whenever the person points us somewhere else.
    onResolvedBinaryChanged: {
        versionChecked = false;
        versionOk = false;
        refresh();
    }

    BoundedProcess {
        id: versionProc
        command: [root.resolvedBinary, "--version"]
        maxBytes: 256
        deadlineMs: 5000
        onFinishedWith: function (out, err, code, tooLarge) {
            root.versionChecked = true;
            root.versionOk = code === 0 && !tooLarge && Version.satisfies(Version.parseVersion(out), Version.MINIMUM);
            if (!root.versionOk) {
                root.state = State.UNUSABLE;
                console.warn("oxidone: no usable binary at", root.resolvedBinary, "— needs >= 1.1.0");
                root.scheduleNext(1);
                return;
            }
            root.refresh();
        }
    }

    BoundedProcess {
        id: todayProc
        command: [root.resolvedBinary, "json", "today"]
        // A day's worth of entries across every List, with room to spare. An
        // answer larger than this is not a day, it is a fault.
        maxBytes: 262144
        deadlineMs: 30000
        onFinishedWith: function (out, err, code, tooLarge) {
            if (code !== 0 || tooLarge) {
                root.consecutiveFailures += 1;
                root.state = tooLarge ? State.STALE : State.stateForExit(code);
                var kind = State.errorKindOf(err);
                console.warn("oxidone: poll failed, exit", code, kind !== "" ? "(" + kind + ")" : "");
                root.scheduleNext(code);
                return;
            }
            try {
                var payload = Today.parseToday(out);
                root.outstanding = Today.outstandingCount(payload);
                root.overdue = Today.hasOverdue(payload);
                root.state = State.OK;
                root.lastSuccess = Date.now();
                root.consecutiveFailures = 0;
                root.scheduleNext(0);
            } catch (error) {
                // A clean exit with an answer we cannot read is our bug, not
                // oxidone's failure. Keep the Snapshot and say so.
                root.consecutiveFailures += 1;
                root.state = State.STALE;
                console.warn("oxidone: unreadable answer:", error.message);
                root.scheduleNext(2);
            }
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalSec * 1000
        repeat: false
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()
}
```

- [ ] **Step 2: Verify it loads and polls**

Run: `omarchy-shell shell rescanPlugins` then `journalctl --user -u omarchy-shell -n 40 --no-pager | grep -i oxidone || true`
Expected: no QML errors. With oxidone installed and authorized, nothing is logged (a successful poll is quiet). With the binary path pointing nowhere, `oxidone: no usable binary at …` appears once.

- [ ] **Step 3: Commit**

```bash
git add Service.qml
git commit -m "feat(service): poll oxidone json today, with a version gate and backoff"
```

---

### Task 7: `Indicator.qml` — the bar presence

**Files:**

- Modify: `Indicator.qml` (replacing the Task 1 placeholder)

**Interfaces:**

- Consumes: the Service's `outstanding`, `overdue`, `state`, `lastSuccess`, and writes its `binaryPath` and `pollIntervalSec` (Task 6).
- Produces: nothing consumed by later tasks in this slice.

- [ ] **Step 1: Write the widget**

`Indicator.qml`:

```qml
import QtQuick
import qs.Commons
import qs.Ui
import "src/state.js" as State

// The bar presence: absent when there is nothing outstanding.
//
// That absence is the point. A permanent count is wallpaper — you stop seeing
// it inside a week. A number that appears only when the day has something in it
// is worth looking at when it does, and an empty bar becomes the reward.
BarWidget {
    id: root

    property var service: bar && bar.shell ? bar.shell.serviceFor("scoop.oxidone") : null

    readonly property int outstanding: service ? service.outstanding : 0
    readonly property bool overdue: service ? service.overdue : false
    readonly property string state: service ? service.state : State.UNUSABLE

    // Auth-needed and an unusable binary both need saying out loud: silence
    // there is indistinguishable from a clear day, which is the one thing the
    // bar must never get wrong.
    readonly property bool needsAttention: state === State.AUTH_NEEDED || state === State.UNUSABLE
    readonly property bool showing: needsAttention || outstanding > 0

    implicitWidth: showing ? row.implicitWidth : 0
    implicitHeight: showing ? barSize : 0
    visible: showing

    function pushSettings() {
        if (!service) {
            return;
        }
        service.binaryPath = setting("binaryPath", "");
        service.pollIntervalSec = setting("pollIntervalSec", 300);
    }

    onSettingsChanged: pushSettings()
    onServiceChanged: pushSettings()
    Component.onCompleted: pushSettings()

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Text {
            anchors.verticalCenter: parent.verticalCenter
            // nf-fa-tasks for the ordinary day; nf-fa-unlink when we cannot ask.
            // Not knowing is not the same alarm as having work to do, and must
            // never be mistaken for it.
            text: root.needsAttention ? "" : ""
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            color: root.needsAttention ? Color.muted : (root.overdue ? Color.urgent : (bar ? bar.foreground : Color.foreground))
            textFormat: Text.PlainText
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.outstanding > 0
            text: String(root.outstanding)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            // While the answer is Stale this count is the last thing we were
            // told, not what is true now. It should not look as certain as a
            // fresh one, and the glyph beside it already admits we cannot ask.
            color: root.state === State.STALE || root.needsAttention ? Color.muted : (root.overdue ? Color.urgent : (bar ? bar.foreground : Color.foreground))
            textFormat: Text.PlainText
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.showing
        // Consent belongs in the TUI, and so does everything slice 1 cannot do.
        // A fixed literal command with nothing interpolated into it: the path
        // the person configured never reaches a shell string.
        onClicked: if (bar) bar.run("omarchy-launch-or-focus-tui oxidone")
        onEntered: if (bar) bar.showTooltip(root, root.tooltipText())
        onExited: if (bar) bar.hideTooltip(root)
        hoverEnabled: true
    }

    function tooltipText() {
        if (state === State.UNUSABLE) {
            return "oxidone not found — needs 1.1.0 or newer";
        }
        if (state === State.AUTH_NEEDED) {
            return "oxidone is not authorized — click to open it";
        }
        if (state === State.STALE && service && service.lastSuccess > 0) {
            return outstanding + " due today — updated " + Qt.formatDateTime(new Date(service.lastSuccess), "HH:mm");
        }
        return outstanding + " due today";
    }
}
```

- [ ] **Step 2: Verify the tokens**

Run: `grep -nE '#[0-9a-fA-F]{3,8}|pixelSize: [0-9]|radius: [0-9]' *.qml`
Expected: no output. Any hit is a literal colour, size or radius, which this plan forbids — replace it with a `Color.*` or `Style.*` token.

- [ ] **Step 3: Commit**

```bash
git add Indicator.qml
git commit -m "feat(indicator): show outstanding work, absent when the day is clear"
```

---

### Task 8: Install, verify live, and document

**Files:**

- Create: `README.md`
- Modify: `manifest.json` only if validation asks for it

**Interfaces:**

- Consumes: everything above.
- Produces: an installed, enabled plugin.

- [ ] **Step 1: Validate and install**

```bash
bun run validate
```

Then install by copying the tree — validation refuses symlinks anywhere in a
plugin folder, so it cannot be linked into place:

```bash
rm -rf ~/.config/omarchy/plugins/scoop.oxidone
mkdir -p ~/.config/omarchy/plugins/scoop.oxidone
tar -cf - --exclude=.git --exclude=node_modules --exclude=.superpowers \
    --exclude=docs --exclude=test --exclude=.husky . \
  | tar -xf - -C ~/.config/omarchy/plugins/scoop.oxidone
omarchy-shell shell rescanPlugins
```

`node_modules` is excluded because bun populates it with symlinks; `.superpowers`
because it is this plan's git-ignored scratch; `docs` and `test` because neither
is loaded at runtime and `omarchy plugin add` copies a repo verbatim.

- [ ] **Step 2: Enable it in the bar**

```bash
omarchy plugin enable scoop.oxidone --section right
```

- [ ] **Step 3: Verify each state by hand**

- [ ] Ordinary day: with work due, the glyph and count appear; with none, the widget is absent from the bar entirely.
- [ ] Overdue: with something dated before today still outstanding, glyph and count are `urgent`.
- [ ] Stale: `sudo ip link set <iface> down` (or disconnect Wi-Fi), wait for the next poll, confirm the count goes `muted` and the tooltip shows `updated HH:MM`. Restore the link and confirm it recovers on the next poll.
- [ ] Auth-needed: point `binaryPath` at a copy of oxidone with `XDG_CONFIG_HOME` set to an empty directory, or temporarily move `~/.config/oxidone/token.json` aside; confirm the unlink glyph appears and the count does not.
- [ ] Version gate: point `binaryPath` at `/usr/bin/true`; confirm the widget shows the unusable state and logs once rather than polling in a loop.
- [ ] Click: confirm it opens or focuses a terminal running oxidone.

Restore `~/.config/oxidone/token.json` afterwards.

- [ ] **Step 4: Write the README**

`README.md` must state, because review checks the README against the code:

- that the plugin requires oxidone >= 1.1.0 installed separately, with a link
- that it reads only; writes arrive in a later release
- that it holds no credentials and never opens a consent flow — oxidone does
- what each bar state means
- the two settings and their defaults
- how to bind a key to it, since a plugin cannot register one itself

- [ ] **Step 5: Run everything and commit**

```bash
bun test && bunx eslint . && bunx prettier --check .
git add README.md
git commit -m "docs: what the widget needs, shows and does not do"
```

---

## Self-review

**Spec coverage.** Indicator, count definition, Today's local filter, colour mapping, states, Snapshot, polling and backoff, deadlines, version gate, tokens, `PlainText`, bounded processes — each has a task. The Pane, writes, and the overlay kind are explicitly slice 2 and 3 and are absent by design.

**Placeholders.** None: every step carries the file's actual content.

**Type consistency.** `outstanding`, `overdue`, `state`, `lastSuccess`, `binaryPath`, `pollIntervalSec`, `refresh()` are spelled identically in Tasks 6 and 7. `State.OK`/`AUTH_NEEDED`/`STALE`/`UNUSABLE` are defined in Task 4 and used in Tasks 6 and 7. `finishedWith(stdoutText, stderrText, code, tooLarge)` is defined in Task 5 and handled with that arity in Task 6.

**Known gap.** `BoundedProcess` takes a deadline and escalates TERM→KILL, but does not put the child in its own process group. `oxidone json` spawns no children of its own, so there is no group to orphan; revisit if a future Bridge ever shells out.
