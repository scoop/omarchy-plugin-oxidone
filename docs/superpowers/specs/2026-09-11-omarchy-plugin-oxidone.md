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
is addressed by absolute path from settings and gated on `>= 1.1.0`. The plugin
ships no executable of its own.

**Indicator.** Nerd Font glyph plus a count, absent from the bar entirely at
zero. The count is **outstanding work in Today**: cross-List, `due <= today`,
undated excluded, still `needsAction`, Tasks and Events but not Notes — the
Due-load's rule, not the Completion meter's.

**Today's drift.** `json today` is status-blind; the glossary admits a Completed
row only if it was completed today. The glossary wins here and the plugin
filters locally until [oxidone#135](https://github.com/erwins-enkel/oxidone/issues/135)
settles it.

**Colour.** `urgent` when anything outstanding is overdue, otherwise
`foreground`; `muted` when Stale. Tokens only — `qs.Commons.Color` and
`qs.Commons.Style`, composed from `qs.Ui`. No literal hex, radius or font size
anywhere in the tree.

**States.** Exit 3 (`auth_expired`, `not_configured`, `token_store_failed`) is
**Auth-needed**: a distinct quiet indicator whose click launches the TUI, where
consent belongs. Exit 4 is **Stale**: keep the Snapshot, go muted. Exit 5 is
Stale with an hour's backoff, since nothing smaller can change a quota. Exits 1
and 2 are plugin faults — stay on the Snapshot, log, never nag.

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

**Writes** (slice 3). Optimistic: apply locally, send, reconcile on the next
poll; the server wins silently on conflict. An outright failure reverts the row
and shows a non-modal inline error that clears on the next good poll.

## Slices

1. **Indicator** — manifest, Service, polling, Snapshot, staleness, auth state,
   version gate. Read-only, no Pane. _This plan._
2. **Pane** — overlay, Today and List scopes, rows, keyboard navigation. Reads only.
3. **Writes** — the eight `apply` ops, optimistic updates, failure handling.

## Marketplace constraints that shape the code

- `textFormat: Text.PlainText` on every `Text` rendering a Google-sourced string
- absolute-path argv arrays, `clearEnvironment: true`, explicit minimal environment
- producer-side output caps; never `StdioCollector`
- an absolute deadline, own process group, TERM→KILL teardown on every child
- no `CLAUDE.md` / `AGENTS.md` / `.claude/` in the installable tree
