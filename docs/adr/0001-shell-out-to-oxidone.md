# The plugin shells out to oxidone; it never talks to Google

Every read and write reaches Google Tasks through a short-lived `oxidone json …`
invocation — a **Bridge**. The plugin contains no OAuth client, no Tasks API code, no
credentials, and no copy of the domain model. It requires oxidone to be installed and
addresses it by an absolute path from its settings, gated on a minimum version.

The obvious alternative is a self-contained plugin: QML and JavaScript over `curl`,
the way `scoop.uptime-kuma` speaks to Uptime Kuma. It would install without a dependency
and review cleanly. It would also be a second Google Tasks client — a second refresh
exchange, a second Tasks REST surface, a second natural-language due-date parser, and a
second definition of **Today** and of the **Entry type** glyph encoding, in a different
language from the first. Those two definitions would be free to disagree, and the first
symptom would be the bar and the TUI showing different numbers for the same morning. A
plugin named after oxidone that shares nothing with oxidone is a plugin that has to be
right twice.

Linking oxidone's library crate into a bundled helper binary would share the code without
the runtime dependency, and was rejected on distribution: the Omarchy marketplace flags
`bundled-executable-binary` for manual review and blocks `cargo-git-unpinned`, and every
user would need a Rust toolchain. Shelling out ships no binary at all — it calls one the
user installed deliberately.

## Consequences

- oxidone gains a public CLI contract it must keep stable (oxidone ADR-0010). The plugin's
  version gate is what makes a breaking change visible rather than mysterious.
- The plugin is useless without oxidone, and says so: a missing or too-old binary is a
  named state in the bar, not an empty widget.
- Credentials never enter this repository's problem space. Consent, refresh, and
  `token.json` are oxidone's, which is also why **Auth-needed** hands off to the TUI
  instead of opening a browser from the shell process.
- Bridges are one-shot, so every child process is trivially bounded — an absolute deadline,
  its own process group, TERM→KILL teardown — which is what the marketplace review asks for
  and what a supervised daemon would have made harder.
- The plugin renders a **Snapshot** rather than reading `oxidone.db`. The cache schema stays
  private to oxidone, and its single-writer design stays true.
