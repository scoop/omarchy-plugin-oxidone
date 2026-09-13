# omarchy-plugin-oxidone

An Omarchy bar plugin that surfaces Google Tasks through [oxidone](https://github.com/erwins-enkel/oxidone). It is a _thin client over the oxidone binary_, never a second Google Tasks client: oxidone owns Google, the credentials, and the domain.

Changing something here? [docs/house-rules.md](docs/house-rules.md) has the house rules and
the gate to run before you claim it works.

## Imported language

The task domain is oxidone's and is not restated here. **List**, **Task**, **Subtask**, **Entry type**, **Signifier**, **Notes**, **Display title**, **Due date**, **Today**, **Migrate**, **Status**, and the four exits are defined in [oxidone's CONTEXT.md](https://github.com/erwins-enkel/oxidone/blob/main/CONTEXT.md) and mean exactly what they mean there. A definition restated in two glossaries is a definition free to drift — in particular **Today**, whose membership the Indicator's count must equal.

One divergence used to live here, and is now closed. `oxidone json today` was status-blind, returning Completed entries whenever they were completed; [erwins-enkel/oxidone#137](https://github.com/erwins-enkel/oxidone/pull/137) narrowed it to today's completions, and the plugin's `>= 1.2.0` floor is what enforces it. The plugin keeps no **Today** filter of its own — the second definition that [#135](https://github.com/erwins-enkel/oxidone/issues/135) existed to remove stays removed.

The terms below are the ones this context adds.

## Language

**Indicator**:
The plugin's element in the Omarchy bar: a glyph and the **Today** count. Absent from the bar entirely when that count is zero.
_Avoid_: badge, widget, applet, tray icon, status item.

**Pane**:
The surface the Indicator opens, where entries are read and changed. Shows **Today** or one **List**, never both.
_Avoid_: popup, panel, dropdown, overlay, window.

**Scope**:
What the Pane is currently showing — **Today**, or a single **List**. The Pane opens on Today; scope is what a capture lands in and what the entry rows belong to.
_Avoid_: view, filter, tab, context.

**Bridge**:
One invocation of oxidone's machine-readable mode — the plugin's only route to Google Tasks. Each Bridge is a fresh short-lived process that reads or writes once and exits; the plugin holds no connection, no credentials, and no Google client of its own.
_Avoid_: backend, API client, daemon, service, RPC.

**Snapshot**:
The last set of entries a Bridge returned successfully, kept by the plugin and rendered whenever a newer one cannot be had. It is _per-machine and non-authoritative_ — never Google's truth, and never oxidone's cache, which the plugin does not read.
_Avoid_: cache, mirror (that is oxidone's live-task store), store, state.

**Stale**:
The state in which the Snapshot is being shown because the last poll failed. Distinct from a count of zero, which is an answer; Stale is the absence of one.
_Avoid_: offline, disconnected, error, unavailable.

**Apply**:
A **Bridge** that changes something: one `oxidone json apply`, one command on stdin, one answer. It differs from the read Bridges only in direction — the same short-lived process, holding the same nothing.
_Avoid_: write (as a noun), mutation, update, request, action.

**Echo**:
The **Entry** an **Apply** returns, as the server left it. The plugin writes the Echo into the **Snapshot** rather than predicting the result, which is why it never holds a **Dirty** state in oxidone's sense. `delete` has no Echo — only the id of what went.
_Avoid_: response, result, optimistic update.

**Pending**:
A row whose **Apply** is queued or sent and not yet answered. Muted and non-interactive, and keyed by **Entry** id rather than by row position, so a refresh underneath it cannot strand it on someone else's row.
_Avoid_: loading, busy, in-flight, dirty.

**Armed**:
A row that has been asked to delete and waits for the confirming second press. Moving the cursor or any change to the **Snapshot** disarms it.
_Avoid_: confirming, pending, selected.

**Auth-needed**:
The state in which oxidone reports no usable grant. The plugin never asks for consent itself — it says so and hands off to the TUI, where consent belongs.
_Avoid_: logged out, unauthenticated, expired.
