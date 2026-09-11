# oxidone bar plugin (scoop.oxidone)

An [Omarchy](https://omarchy.org) bar plugin that shows what's due today in
Google Tasks, read through the [oxidone](https://github.com/erwins-enkel/oxidone)
CLI.

## Requirements

- **oxidone >= 1.1.0**, installed separately. Get it from
  [erwins-enkel/oxidone](https://github.com/erwins-enkel/oxidone) and
  authorize it once (`oxidone`) before this plugin can show anything but the
  auth-needed state.

The plugin does not vendor or install oxidone itself. If the configured
binary is missing or older than 1.1.0, the plugin shows its unusable state
rather than guessing.

## This release is read-only

This first release only reads: it polls `oxidone json today` on an interval
and reflects the answer in the bar. It does not create, edit, complete, or
otherwise write anything. Writing is planned for a later release.

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
| Unusable       | The same unlink glyph, no count — no working oxidone binary was found at the configured path, or it's older than 1.1.0.                                 |
| Nothing due    | Nothing. The widget is entirely absent from the bar.                                                                                                    |

Clicking the widget opens or focuses a terminal running oxidone. It does this
by running `omarchy-launch-or-focus-tui oxidone`, which resolves `oxidone`
from your `PATH` — it does not use the `binaryPath` setting below. If
`binaryPath` points somewhere outside your `PATH`, the click opens whichever
`oxidone` your shell finds there, or none. This is deliberate: the host's only
launch API takes a shell string, and interpolating a user-supplied path into
one is exactly what the plugin security rules forbid.

## Settings

| Setting           | Default                | Notes                                                                |
| ----------------- | ---------------------- | -------------------------------------------------------------------- |
| `binaryPath`      | `~/.local/bin/oxidone` | Absolute path to the oxidone binary. Leave empty to use the default. |
| `pollIntervalSec` | `300`                  | How often to poll, in seconds. Range 60–3600.                        |

## No keybinding yet

There is nothing to toggle in this release: the widget is read-only, with no
Pane to open, so it exposes no `open()` for `omarchy-shell shell toggle` to
call. A keybinding arrives together with the Pane in a later release.
