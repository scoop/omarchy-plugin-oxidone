# omarchy-plugin-oxidone — design

Settled in a grilling session on 2026-09-11. This is the record of what was
decided and why; the glossary is [CONTEXT.md](../../../CONTEXT.md) and the
central architectural decision is
[ADR-0001](../../adr/0001-shell-out-to-oxidone.md).

## Goal

An Omarchy (Quattro) bar plugin that shows what is due today and lets the day's
task work happen without opening the TUI — built as a thin client over the
`oxidone` binary, never as a second Google Tasks client.

## Non-goals

- Talking to Google. Every read and write is a **Bridge**: one short-lived
  `oxidone json …` process.
- Holding credentials. Consent, refresh and `token.json` stay oxidone's.
- Reimplementing the domain. `display_title`, `type`, Migrate's date maths and
  the due-date vocabulary all arrive from the CLI already resolved.
- Replacing the TUI. The Weekly spread, notes editing, reordering, re-parenting
  and List moves stay where they are.

## The contract it consumes

`oxidone json`, shipped in **oxidone 1.1.0** — `docs/json-cli.md` in that repo
is authoritative. Slice 1 uses only:

- `oxidone json today` → `{"today": "YYYY-MM-DD", "entries": [Entry, …]}`
- `Entry` → `{id, list, parent, title, display_title, type, has_notes, due,
status, completed_at, position}` where `type` is `task|event|note` and
  `status` is `needsAction|completed`
- failures print `{"error":{"kind","message"}}` on **stderr** with exit codes
  1–7; stdout stays empty

## Decisions

**Distribution.** Marketplace-published. Requires oxidone installed; the binary
is addressed by absolute path from settings and gated on `>= 1.2.0`. The plugin
ships no executable of its own.

**Indicator.** Nerd Font glyph plus a count, absent from the bar entirely at
zero. The count is **outstanding work in Today**: cross-List, `due <= today`,
undated excluded, still `needsAction`, Tasks and Events but not Notes — the
Due-load's rule, not the Completion meter's.

**Today's drift.** ~~`json today` is status-blind; the glossary admits a
Completed row only if it was completed today. The glossary wins here and the
plugin filters locally until
[oxidone#135](https://github.com/erwins-enkel/oxidone/issues/135) settles
it.~~ **Superseded by "Today's definition moves upstream" in Slice 2
decisions:** #135 was settled by oxidone#137, which narrowed `json today`
upstream. The plugin carries no local filter, and the 1.2.0 floor is what
enforces it.

**Colour.** `urgent` when anything outstanding is overdue, otherwise
`foreground`; `muted` when Stale. Tokens only — `qs.Commons.Color` and
`qs.Commons.Style`, composed from `qs.Ui`. No literal hex, radius or font size
anywhere in the tree.

**States.** Exit 3 (`auth_expired`, `not_configured`, `token_store_failed`) is
**Auth-needed**: a distinct quiet indicator. (Its click launched the TUI
directly in slice 1; see "The click changes meaning" in Slice 2 decisions —
the click now opens the Pane, which makes the TUI its primary action, since
re-consenting is the one thing the Pane cannot do.) Exit 4 is **Stale**: keep
the Snapshot, go muted. Exit 5 is Stale with an hour's backoff, since nothing
smaller can change a quota. Exits 1 and 2 are plugin faults — stay on the
Snapshot, log, never nag.

**Snapshot.** The last good answer, held in memory by the `keepLoaded` Service.
Not persisted to disk in slice 1: the first poll lands seconds after the shell
starts, and a file written on every poll buys a few seconds of cold-start
accuracy for the exact symlink- and predictable-path-race surface that review
scrutinises hardest. Revisit if cold starts prove annoying.

**Polling.** Every 5 minutes by default (configurable), immediately on open, with
exponential backoff to a 30-minute ceiling. Reads get a 30s deadline — `today`
fans out one request per List, so its cost scales with List count and killing it
early only guarantees permanent staleness. Writes get 10s, because a click is
waiting.

**Pane** (slice 2+). Opens on Today — the same set the badge counts — with a
selector to scope to one List. Keyboard-first with the TUI's own bindings where
they fit, mouse fully supported. Row actions revealed on focus or hover. Flat on
Today, nested one level in List scope. Capture follows the Pane's scope.

**Writes** (slice 3). ~~Optimistic: apply locally, send, reconcile on the next
poll; the server wins silently on conflict. An outright failure reverts the row
and shows a non-modal inline error that clears on the next good poll.~~
**Superseded by "Echo, not optimism" in Slice 3 decisions:** written before we
knew `json apply` answers with the Entry the server left. There is no local
apply, so there is nothing to reconcile and nothing to revert.

## Slices

1. **Indicator** — manifest, Service, polling, Snapshot, staleness, auth state,
   version gate. Read-only, no Pane. _Shipped._
2. **Pane** — overlay, Today and List scopes, rows, keyboard navigation. Reads only.
   _Shipped._
3. **Writes** — `complete`, `uncomplete`, `migrate`, `delete`; Echo-driven; the
   Apply queue and the failure surface. _Shipped._
4. **Text** — `create`, `retitle`, `set_due`, `clear_due`, and the editor all
   four need. _Shipped._

## Slice 2 decisions

**Kind.** `overlay`. The shell treats `panel`/`overlay`/`menu` identically — one
Loader, one `entryPoints` key — and the plugin builds its own `PanelWindow` and
decides its own geometry. `overlay` is the convention for a full-screen scrim
plus a centred card, which is what this is.

**Contract.** The entry point exposes `open(payloadJson)`, `close()` and a
`readonly property bool opened`; the shell's `toggle`/`summon`/`hide` and
`isPluginOpen` are all defined in terms of those three.

**The click changes meaning.** Declaring `overlay` excludes the plugin from the
bar-widget summon path, so the Indicator's click routes to the Pane instead of
the TUI. The TUI does not become unreachable: the Pane's footer offers it, and
the Auth-needed state makes it the primary action, since that is the one thing
the Pane cannot fix.

**Keyboard.** Use `qs.Ui.PanelKeyCatcher` rather than hand-rolling a
`Keys.onPressed` block. It already gives `moveRequested`, `activateRequested`,
`closeRequested`, `deleteRequested` and `textKey`, and — the part that matters —
a `blocked` flag so an inline text field can own the keyboard without the
catcher stealing from it.

**List rendering.** There is no shared list component; every first-party panel
hand-builds a `ListView` with its own delegate. Follow the house recipe:
`ListView` + delegate, `PanelSectionHeader` for group headers, `PointerMoveGate`
so a list moving under a still pointer cannot steal the keyboard cursor, and
`CursorSurface` semantics so only one highlight exists on screen.

**Today's definition moves upstream.** oxidone#137 narrowed `json today` to
today's completions, with timezone handling. The floor therefore rises to the
release carrying it, and the plugin keeps no completed-today filter of its own —
the second definition of Today that #135 existed to remove stays removed.

## Marketplace constraints that shape the code

- `textFormat: Text.PlainText` on every `Text` rendering a Google-sourced string
- absolute-path argv arrays, `clearEnvironment: true`, explicit minimal environment
- producer-side output caps; never `StdioCollector`
- an absolute deadline, TERM→KILL teardown on every child
- no `CLAUDE.md` / `AGENTS.md` / `.claude/` in the installable tree

## Slice 3 decisions

Settled in a grilling session on 2026-09-12, over 25 questions in five rounds.

**The op set.** Four: `complete`, `uncomplete`, `migrate`, `delete` — the four
dispositions minus Scheduled, plus `uncomplete` as the repair for a mis-tap. The
other four all need a text field, which brings an inline editor, IME, paste, and
the first titles this plugin _produces_ rather than receives. That is slice 4.

**Echo, not optimism.** Every op but `delete` answers with the Entry as the
server left it. The plugin sends, marks the row **Pending**, and writes the
**Echo** into the Snapshot — it never predicts a result. So there is no **Dirty**
state in oxidone's sense, no reconcile window, and no revert path. The cost is
one process spawn and one round trip of a muted row; in a pure mirror,
wrongly-instant is worse than honestly-slow.

**Both scopes write.** Every Entry carries its own `list`, so an Apply is
addressable from Today as readily as from a List — and Today is where the daily
review happens.

**Keys mirror the TUI** — `Space`, `m`, `x` — with a gate on `x` alone: it
**Arms** the row, a second `x` commits, Esc or any other key cancels, and moving
the cursor or any Snapshot change disarms. Enter keeps meaning "open the TUI";
overloading it as confirm is how people delete what they meant to open. Note the
trap oxidone's glossary names: BuJo's `X` is _complete_, oxidone's `x` is
_delete_.

**No undo stack.** `Space` is its own inverse. Migrate composes a day at a time,
so a stray press is self-healing. Delete has no inverse in the CLI at all —
Google's soft delete is recoverable only in Google's own UI, which the confirm
copy says, since we cannot offer it. An undo stack would mean holding pre-write
state: the second source of truth ADR-0001 forbids.

**Stale neither blocks an Apply nor is caused by one.** oxidone owns the
judgment — exit 4 says the network is still down, exit 6 that the Entry is gone.
Stale stays exactly what slice 2 made it: a fact about a Today poll.

**No local pre-flight.** `migrate` on a Completed Entry is refused with exit 7,
and the plugin sends it anyway rather than encoding a rule it does not own. A
duplicated rule drifts the moment oxidone relaxes it. The cost is one short-lived
process on a mis-press.

**Errors speak in the plugin's words**, chosen by exit code; oxidone's `message`
goes to the log. Those messages are serde's and Google's — `unknown variant … at
line 1 column 28` is a developer's sentence, not a user's. Nothing remote reaches
the Pane, so no untrusted string exists on that path to sanitize.

**The Apply queue lives in the Service**: one in flight, FIFO, capped at 32, each
queued row Pending, a 10s deadline each. Writes continue through a Pane close —
cancelling a request already at Google buys nothing and discards the Echo. The
queue does not survive a shell restart; persisting it would mean writing a file
at a predictable path on every keystroke, the surface slice 1 refused for the
Snapshot.

**One process wrapper.** `BoundedProcess` gains an optional stdin payload,
written on start, then `stdinEnabled` cleared so the child sees EOF (verified
against Quickshell 0.3.1: the pipe closes and the child exits). The payload is
never argv, exactly as `json apply` requires. Same ceiling, deadline, teardown
and cleared environment as every read.

**Writes are on, with no setting.** The confirm gate is the mitigation; a
checkbox is documentation, which review treats as no mitigation at all. The
README's "This release is read-only" goes, replaced by a plain statement of what
a keystroke can change.

**Testing.** A fake oxidone under `test/` answers `apply` from a fixture and
returns any exit on demand, so every failure branch is reachable without a
network. It is untracked and written by `test/make-fixture.js`, so it never
enters the installable tree: `omarchy plugin add` clones the whole repository and
`omarchy plugin update` needs that checkout to stay a git working tree, so there
is no packaging step that could exclude a committed file. One live check at the
end, against a throwaway task.

Where a question is about QML itself rather than about a pure function — binding
order, an epoch guard, what the Service does when the binary under it changes —
`test/qml/harness.qml` runs the real Service under `qs`, offscreen and without a
Wayland session. Its config folder, and the fake binaries it swaps the Service
between, are written to a temp directory as the test runs rather than committed:
`qs` will not import QML from outside the folder it is given, the marketplace
validator refuses symlinks inside a plugin, and by the rule above a committed
fake would be an executable sitting on every user's machine. It skips itself
where `qs` is absent, which is anywhere that is not a machine this plugin could
run on — so, like `bun run validate`, it is a gate the local run enforces.

**The Indicator does not move while an Apply is in flight.** It is a glance
surface; a sub-second Pending state would flicker at the edge of vision. The
count moves when the Echo lands.

## Slice 4 decisions

Settled with the operator over three question rounds, against oxidone's
`docs/json-cli.md` and its TUI's own `capture_target`.

**Capture mirrors the TUI, and costs two Applies in Today.** `apply create`
takes `list` and `title` and no due date, but oxidone's own capture dates a
Today capture _today_ — "so the entry stays on the page it was created on"; its
other panes leave one undated. Today scope therefore sends `create` into
`default_list` and then `set_due` with the Snapshot's own `today`. A List
capture stays one Apply, undated. This is the plugin's first multi-Apply
operation, and it can half-succeed: when it does, the strip says the entry was
created but not dated, and names the List it is in. No retry and no cleanup —
the entry is real, and a retry policy nothing else in the queue has would buy
less than one honest sentence.

**Every capture carries its own key, in its own store.** The strip stays open
for a run, so two captures can be in flight at once. A shared key would let the
second capture's enqueue clear the first's message, and the first answer clear
both rows' Pending. `applyPending` and `applyErrors` stay keyed by Entry id, for
row ops only: a capture has no Entry id, and a sentinel parked in `applyErrors`
would never be cleared at all, since `retainErrorsAbsentFrom` drops only keys
that come back as entry ids in a fresh answer. Captures live in a `captures` map
of their own, each failure named by the title it carried, the last five kept,
cleared when the strip closes.

**The due field speaks oxidone's whole vocabulary, resolved on commit.**
`apply set_due` takes ISO and only ISO; `oxidone json due <expr>` — pure, no
network, no credentials, refused before anything authorizes — is what turns
`tomorrow` or `+3d` into one, and it exists so a caller need not write a second
date parser. No live preview: a process per keystroke-pause is a debounce, a
stale preview and a second failure mode, for a date the commit is about to name
anyway. **An empty field commits `clear_due`**, so one key reaches both ops
while they stay the two separate commands the contract requires.

**The retitle editor seeds the raw `display_title`.** `Rows.plain` replaces
control characters and truncates at 200 with an ellipsis — rendering rules, and
saving their output back as the new name would silently shorten a long title and
flatten a mixed-direction one. This is the one unsanitized Google string in the
Pane, and it is safe to be: a `TextInput` renders no markup, has no `textFormat`
to get wrong, and the field is clipped, so a hostile title can disrupt its own
field and nothing else.

**Today still has one definition.** Every op that changes a date folds its Echo
— honest, it is what the server said — and then re-reads Today, so oxidone
answers membership and ordering. Only two derivations stay local, both from what
the op does rather than from a `due <= today` test: `clear_due` leaves Today
because an undated entry is never in it, and a Today capture's chained `set_due`
enters Today because the date it sets is the Snapshot's own. The re-read is the
backstop that makes either self-correcting inside one read.

**One editor strip, under the selector.** One field, three jobs, one geometry
and one `blocked` binding — and the row being edited stays visible and cursored
below it rather than hidden behind it. `blocked` follows `editorMode` rather
than the field's focus, so a click that takes focus elsewhere cannot hand `x`
back to a row while a rename is half-typed above it.

**Delete is still the only gated op.** Every text op is redoable by doing it
again, and the editor's Esc is its own gate: nothing is sent until Enter.

**The fixture learned to fail one op at a time.** A Today capture is two
Applies, so the half-capture branch is only reachable when the `create` lands
and the `set_due` behind it does not — which a failure aimed at every op cannot
produce. `test/make-fixture.js` gained `~/.fake-oxidone-fail-op` beside the
exit-code channel, and a `json due` subcommand. Its template stays ASCII and
backtick-free, and writes a literal `${` as an interpolated `"$"`, for the
reasons its own header gives.

**One user-typed string reaches argv**, the due expression, because `json due`
takes it as an argument and there is no other route. Titles and ids stay on
stdin. A date phrase is not a task title, the process lives milliseconds, and
oxidone's `json` arg parsing joins everything after the subcommand verbatim, so
a leading `-` is data rather than a flag.
