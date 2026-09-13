# House rules

Read this before changing anything here. It is the posture a reviewer would otherwise have
to repeat every time.

This project is an Omarchy bar plugin that reads and writes Google Tasks by shelling out to
the `oxidone` binary. QML for the surface, plain JavaScript for the logic, bun for the tests.

**This file is deliberately not `CLAUDE.md` or `AGENTS.md`, and must not be renamed to
either.** See [What ships](#what-ships): `omarchy plugin add` clones this repository into
the user's `~/.config/omarchy/plugins/`, so a file by either name would land in a tree where
people run coding agents to tweak their desktop, and this repository's house rules would
become standing instructions in a stranger's environment.

Both names are in `.gitignore`, and `install-dev` excludes them from the tarball it writes
into that same directory, so neither route can carry one onto a machine by accident. With
both exits closed you can safely keep an untracked local `CLAUDE.md` pointing here if you
want these rules auto-loaded while you work.

## Before you write

Read [CONTEXT.md](../CONTEXT.md). Its glossary is this project's vocabulary — **Indicator**,
**Pane**, **Scope**, **Bridge**, **Snapshot**, **Stale**, **Apply**, **Echo**, **Pending**,
**Armed**, **Auth-needed** — and every entry names the words it displaces. Use those words
in code, comments, commits and PR text; reaching for a synonym is how a second definition
starts. The task domain itself is oxidone's and is deliberately not restated here.

Architectural decisions live in `adr/`. [ADR-0001](adr/0001-shell-out-to-oxidone.md)
is the load-bearing one: the plugin holds no credentials, no Google client, and no copy of
the domain model, and each of those absences was paid for. Read it before adding anything
that talks to a network.

## The gate

`bun run verify` — format, lint, typecheck, tests, fallow audit. `.husky/pre-push` runs
that one script and so does CI, which is what keeps the two from drifting. Run it before
you claim a change works.

`bun run validate` runs Omarchy's own plugin validator and needs Omarchy installed, so CI
cannot run it for you. Run it locally whenever you touch `manifest.json`, a `.qml` file,
or anything about what ships.

## Releases

release-please owns the version. Nobody edits `manifest.json`'s or `package.json`'s `version` by
hand — the commit type decides: a `fix:` buys a patch, a `feat:` a minor, a `!` or a
`BREAKING CHANGE:` footer a major, and everything else buys nothing. The workflow keeps a release
pull request open and rewritten as commits land; merging it is the release, and tags the commit
and publishes the GitHub Release.

Two version fields move together. `package.json` is the node strategy's own; `manifest.json` is an
`extra-files` updater in `.github/release-please-config.json`, and **it is the one that matters** —
`omarchy plugin add` clones the default branch and the marketplace reads `manifest.json` at that
same tip, so its `version` is the only one a user or the plugin directory ever sees. That updater
fails quietly, logging a warning and opening a release PR that looks fine, which is why
`test/manifest-version.test.js` fails the gate when the two drift.

Four things about this that have no room for a comment where they live:

- `CHANGELOG.md` is in `.prettierignore`. release-please writes `*` bullets and double blank lines,
  prettier rewrites both, and `bun run verify` would fail on `main` after every release.
- Every JSON file release-please rewrites gets `printWidth: 1` in `.prettierrc`. Its updaters
  re-serialize the whole file with `JSON.stringify(_, null, 2)`, which always puts one array
  element per line; prettier at the normal width pulls short arrays back onto one, so
  `manifest.json`'s `kinds` alone would have failed the gate on every release. At `printWidth: 1`
  prettier's output is byte-identical to `JSON.stringify`, so the two agree and the files stay
  formatted rather than ignored. Add a file to that override list before letting release-please
  write to it.
- `bootstrap-sha` in the config pins where the changelog starts, because release-please finds the
  previous release by listing GitHub _Releases_ — a bare tag is invisible to it. Without the pin, a
  missing release makes it walk hundreds of commits and backfill the lot. It is dead config once a
  release exists and can be deleted.
- The release PR gets no CI. It is opened by `GITHUB_TOKEN`, which by design does not trigger
  `pull_request` workflows; `ci.yml` still runs on the push to `main` behind it.

Tags are for humans and for the marketplace's `[Verify]` form, which binds a listing to one exact
40-character SHA. No Omarchy command reads them — `omarchy plugin add` and `omarchy plugin update`
both track the tip of the default branch.

## What the guardrails can't catch

**Fail closed.** A Bridge that fails leaves the Snapshot standing and the plugin says
**Stale** — it never renders the failure as an answer. Hold that line in new code: a
swallowed error, an empty result, or a zero count must never reach the bar dressed as
success. **Stale** and a genuine count of zero are different states and look different.

**Single source of truth.** Derive counts, totals and bounds from the data — array length,
the Snapshot's own contents. The Indicator's count must equal **Today**'s membership
because it is computed from it, not because two places agree today. `oxidone` owns the
**Today** filter; the plugin keeps none of its own.

**Keep names and comments honest.** The comments here carry reasons, not restatements —
why the fixture is untracked, why a template stays ASCII, why `json today` needed a version
floor. When you change what a function does, change its name, its doc comment and the
comments around it in the same edit. A stale comment outranks the code in a reader's head,
which is what makes it worse than no comment.

## The QML/JavaScript boundary

Each module in `src/` is loaded from QML by path (`import "src/state.js" as State`) and
from the tests by import. Two consequences:

- Every file ends with an `if (typeof module !== "undefined")` guard around its
  `module.exports`, because QML has no `module`. A new module needs the same guard, and
  `src/` stays pure functions — no I/O, no QML types — so the shell and the test runner
  load the identical file.
- **Static analysis cannot see QML.** Nothing parses `.qml` here, so fallow is configured
  to treat all of `src/**/*.js` as dynamically loaded. Before deleting an export that
  looks unused, grep the `.qml` files for it.

`src/` is written in ES5-era JavaScript — `var`, `function`, string concatenation — and
eslint turns off `no-var` and `prefer-const` to keep it that way. Match the surrounding
dialect rather than modernising it. `test/` is ESM and may use anything bun runs.

## What ships

`omarchy plugin add` clones this whole repository and moves it to
`~/.config/omarchy/plugins/scoop.oxidone`. It is a plain `git clone` with no filtering, so
**anything committed installs on every user's machine** — there is no packaging step to
exclude a file from. Weigh every new committed file against that.

Two consequences that have already shaped this repository:

- `test/make-fixture.js` generates the fake-oxidone fixture rather than the repository
  carrying it, so an executable test double never installs on a user's machine.
- A file that some _other_ tool treats as instructions is worse than a large one, because it
  keeps acting after it lands. `CLAUDE.md` and `AGENTS.md` are the live example and are
  gitignored; think the same way before committing an `.editorconfig`, a `.envrc`, or
  anything else a user's tooling picks up by name.
