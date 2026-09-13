# oxidone bar plugin (scoop.oxidone)

An [Omarchy](https://omarchy.org) bar plugin that shows what's due today in
Google Tasks, read through the [oxidone](https://github.com/erwins-enkel/oxidone)
CLI.

## Installing

```bash
omarchy plugin add https://github.com/scoop/omarchy-plugin-oxidone --enable
```

This plugin needs manual setup beyond that: oxidone must be installed and
authorized separately (see Requirements below). Until it is, the widget shows
its auth-needed or unusable state rather than a count.

## Requirements

- **oxidone >= 1.2.0**, installed separately. Get it from
  [erwins-enkel/oxidone](https://github.com/erwins-enkel/oxidone) and
  authorize it once (`oxidone`) before this plugin can show anything but the
  auth-needed state. 1.2.0 is the floor because that release narrowed
  `json today` to today's completions; on 1.1.0 the list would show entries
  completed weeks ago.

The plugin does not vendor or install oxidone itself. If the configured
binary is missing or older than 1.2.0, the plugin shows its unusable state
rather than guessing.

## What it can change

This release reads on a poll and can change what follows, each from a single
key in the pane:

| Key     | What it does                                                                                                      |
| ------- | ----------------------------------------------------------------------------------------------------------------- |
| `Space` | Completes the entry, or reopens it if it is already complete.                                                     |
| `m`     | Migrates it — its due date moves to tomorrow, or a day past its own due date if that is later, and it stays open. |
| `x`     | Deletes it. Press `x` once to arm the row, then `x` again — or click the row's delete button — to confirm.        |
| `a`     | Captures a new entry from a title. See "Capturing" below.                                                         |
| `e`     | Renames it. The field opens with the current title; the entry keeps its type.                                     |
| `d`     | Sets its due date, or clears the date if you empty the field and press Enter.                                     |

Every change is one `oxidone json apply`, with the command on the process's
standard input rather than its arguments. The pane shows only what oxidone
answers with: a row waits, muted, until the change is confirmed, and a change
that fails says so on the row. The plugin never changes an entry itself, so a
failure leaves it exactly as oxidone last reported it — and a row whose entry
turns out to be already gone from Google simply disappears. Nothing is applied
locally first, so what you see is never a guess about what Google did.

Deleting has no undo here. Google keeps a deleted task recoverable in its own
web client, which is why the confirm prompt says so — this plugin cannot bring
one back. Nothing else is gated: a rename or a date can simply be typed again.

### Capturing

`a` opens a field under the scope selector, and the field says where the entry
will land. In a list, that is the list on screen, and the entry is created
undated. In Today — which is no list — it goes to the list oxidone resolves as
your default, and is dated today, so it stays on the page you typed it on.
Dating it is a second request, which is why a capture there can report that the
entry was created but could not be dated; when it says that, the entry is real
and undated in the list it names.

The field stays open after each entry, so a run of them is type, Enter, type,
Enter. Escape closes it. The title is written exactly as typed — a leading `○`
or `—` makes an Event or a Note, the same thing that happens in Google's own
web client.

### Due dates

`d` accepts what oxidone's own due editor accepts — `tomorrow`, `mon`, `+3d`, a
bare `25` for the next 25th, or an ISO date. The phrase is resolved by oxidone
before anything is written, so what gets saved is a date it agreed to; a phrase
that is not a date says so on the row and changes nothing.

## Credentials and authorization

This plugin holds no credentials and never starts an OAuth consent flow.
oxidone owns the Google account, the token, and all of Google Tasks access —
every read is one short-lived `oxidone` process that this plugin spawns,
reads the answer from, and lets exit. When oxidone reports it has no usable
grant, the plugin says so and stops there; getting authorized again means
running oxidone yourself, outside the plugin.

## What the bar shows

| State          | What you see                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Work due today | A glyph and the count of outstanding items.                                                                                                             |
| Overdue        | The same glyph and count, colored to draw the eye — something outstanding is dated before today.                                                        |
| Stale          | The last known count, muted, when a poll fails for a reason other than authorization (e.g. a network blip). The tooltip shows when it was last updated. |
| Auth-needed    | A distinct unlink glyph, no count — oxidone has no usable Google grant.                                                                                 |
| Unusable       | The same unlink glyph, no count — no working oxidone binary was found at the configured path, or it's older than 1.2.0.                                 |
| Nothing due    | Nothing. The widget is entirely absent from the bar.                                                                                                    |

Clicking the widget opens the pane described below, rather than launching a
terminal directly. From inside the pane, Enter or the "Open oxidone" button
launches `omarchy-launch-or-focus-tui` (by absolute path) and closes the
pane.

## The pane

The pane is a keyboard-first overlay listing what oxidone reports, grouped
Overdue then Today; each group header carries the count of what is still
outstanding in that group. A completed entry is shown struck through and
muted, and is never counted. A scope selector switches between Today and any
single List, showing that list's entries in the CLI's own Manual order with
subtasks indented one level under their parent.

For the states a list cannot represent — auth-needed, unusable, or a stale
Today poll — the pane shows a message instead, with a button to open oxidone
where that's the only way forward.

| Key              | Action                                                      |
| ---------------- | ----------------------------------------------------------- |
| `j` / `k`, ↓ / ↑ | Move the cursor between entries                             |
| `h` / `l`, ← / → | Switch scope (Today, or a List)                             |
| `Space`          | Complete the entry, or reopen it                            |
| `m`              | Migrate it to the next day                                  |
| `x`              | Delete it — once to arm, again to confirm                   |
| `a`              | Capture a new entry                                         |
| `e`              | Rename the entry                                            |
| `d`              | Set its due date — empty the field to clear it              |
| Enter            | Open oxidone and close the pane                             |
| Esc              | Close the editor, cancel an armed delete, or close the pane |

The row under the cursor, or under the pointer, also reveals buttons for the
same complete, rename, due, migrate and delete actions. The delete button arms
the row and then stays put, in place of the other four, so a second click on it
confirms — `x` and the button reach the same gate, and either one can arm a row
the other one finishes. Capture has no row to hover, so its button sits beside
the scope selector.

## Settings

| Setting           | Default                | Notes                                                                |
| ----------------- | ---------------------- | -------------------------------------------------------------------- |
| `binaryPath`      | `~/.local/bin/oxidone` | Absolute path to the oxidone binary. Leave empty to use the default. |
| `pollIntervalSec` | `300`                  | How often to poll, in seconds. Range 60–3600.                        |

## Keybinding

The plugin cannot register one itself. To bind a key, add this to your own
Hyprland config:

    bind = SUPER, T, exec, omarchy-shell shell toggle scoop.oxidone '{}'

That toggles the same pane the widget's click opens — see "The pane" above
for what it shows and its keys.

## What it touches

The plugin writes no files. There is no state file, no cache on disk, no
keyring entry, no systemd unit, no hook, and no edit to any shared
configuration. The last known count is held in memory for as long as the
shell runs and is gone when it stops.

It makes no network connections of its own. Everything it runs is the
configured `oxidone` binary — as `oxidone json today` on its poll, as
`oxidone json lists` / `oxidone json tasks --list <id>` when the pane's scope
selector is used, and as `oxidone json apply` when you change something — with
a fixed minimal environment; oxidone is what talks to Google, using its own
credentials. An `apply` command is written to that process's standard input,
never passed as an argument, because a process's arguments are readable by
every program running as you — so no task title and no task id ever appears in
an argument list. Setting a due date runs one more read, `oxidone json due
<what you typed>`, which is the one place a string you typed is passed as an
argument: that subcommand takes it that way and there is no other route. It
needs no credentials and makes no network request of its own. Opening the TUI from the pane runs
`omarchy-launch-or-focus-tui` the same way: an absolute-path process, its
argument passed as its own array element. Nothing in this plugin runs through
a shell.

## Removing

```bash
omarchy plugin remove scoop.oxidone
```

That removes the plugin and its entry from your bar. Nothing of this
plugin's survives removal, because it stores nothing.

Two things it never touched are also left alone, and are yours to remove if
you want them gone:

- **oxidone itself**, including its config and Google token in
  `~/.config/oxidone/` — installed separately, removed separately.
- **A keybinding**, if you added one yourself. This release ships none.
