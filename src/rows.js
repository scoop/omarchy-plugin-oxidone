// The Pane's row model. Pure functions only — no QML, no I/O — so the test
// runner and the shell load the same file.
//
// Today is laid out the way the TUI's Journal spread lays it out: an Overdue
// group, a Today group, and the entries under each. Grouping is status-blind,
// which is what keeps each group a contiguous run; the count in the header is
// narrower, because it answers the migration ritual's question — what is left
// to move — and a Completed row is not.

/** Longest title drawn. Beyond this the row stops being a row. */
var MAX_TITLE = 200;

// Everything below comes from Google by way of the CLI: a title is whatever
// someone typed, on any device. Control characters and the bidi format
// controls can reorder or break a row inside the shared shell process, and an
// unbounded title pushes every other column off screen. Replace rather than
// delete, so two words never silently become one.
function plain(text, max) {
  var limit = max || MAX_TITLE;
  // The class below is written as escapes on purpose: literal control bytes in
  // a source file are what stop the marketplace's baseline scanner dead.
  var out = String(text === undefined || text === null ? "" : text).replace(
    /[\u0000-\u001F\u007F-\u009F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]/g,
    " ",
  );
  if (out.length > limit) {
    var cut = limit - 1;
    // Never cut between a surrogate pair: the orphaned half renders as a
    // replacement glyph right where the eye lands, at the elision.
    var last = out.charCodeAt(cut - 1);
    if (last >= 0xd800 && last <= 0xdbff) {
      cut -= 1;
    }
    out = out.slice(0, cut) + "…";
  }
  return out;
}

// Everything `plain()` does, and then the markup characters as well — for the
// sinks this plugin hands a string to but does not draw itself.
//
// A `Text` this plugin owns is pinned to `Text.PlainText`, so `<` and `&` are
// just characters there and a task honestly named "A & B" has to keep reading
// that way. That is why `plain()` must not strip them, and why this is a
// second helper rather than a wider `plain()`.
//
// A host component owns its own format. QtQuick Controls' Basic style draws a
// TextField's placeholder with a `Text` that sets no `textFormat` at all, so
// `Text.AutoText` decides, and a string that looks like markup is parsed as
// markup — which for `<img src="http://…">` means the shell process fetches a
// URL a stranger's list name chose. There is no property on this side to pin,
// and the host's file is not this plugin's to depend on, so the markup has to
// be gone before the handoff.
//
// Replaced rather than deleted, for the same reason `plain()` gives.
function hostText(text, max) {
  return plain(text, max).replace(/[<>&]/g, " ");
}

// The one date shape this plugin recognises, and the only one it will seed a
// date editor from.
//
// `src/today.js` tests the same shape on the way in, where it decides whether
// an answer oxidone gave is usable. This is the way out: a `due` field is a
// string oxidone printed, the Pane's `d` seeds the editor with it, and Enter on
// an unedited editor puts that string in an argument list. Two copies rather
// than one because neither module imports the other — each is loaded on its own
// by the QML engine — and because the two answer different questions.
var ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function isIsoDate(value) {
  return typeof value === "string" && ISO_DATE.test(value);
}

/** Longest date phrase handed to `oxidone json due`. */
var MAX_DUE_EXPR = 128;

// What may become an argument to `oxidone json due`.
//
// The editor's own `maximumLength` is shared with capture and retitle, where a
// long title is legitimate, so the bound on a date phrase belongs here instead:
// "next tuesday" is twelve characters and nothing a person types into a date
// field is near this cap.
//
// The character rule is `plain()`'s, reused rather than restated: if drawing
// this string would have meant replacing something in it, it is not a string to
// hand to another process either. Note what is deliberately *not* here — no `--`
// and no refusal of a leading `-`. `oxidone json due` joins everything after
// the subcommand into the phrase verbatim, so `--` becomes part of the date and
// `-3d` is a date this has to keep being able to send.
function isDueExpr(value) {
  if (typeof value !== "string" || value === "" || value.length > MAX_DUE_EXPR) {
    return false;
  }
  return plain(value, MAX_DUE_EXPR) === value;
}

// The Entry type's signifier, as the TUI draws it: an Event happens on a day,
// a Note is a jotting, and a Task — the default — carries none.
function signifierFor(type) {
  if (type === "event") {
    return "○";
  }
  if (type === "note") {
    return "—";
  }
  return "";
}

// A date is worth printing only when it is not today's: the pane is already
// today, so repeating it on every row is noise. Year-less and ISO-ordered, so
// it reads the same everywhere.
function dueLabel(due, today) {
  if (typeof due !== "string" || due === "" || due === today) {
    return "";
  }
  return due.slice(5);
}

function isOverdue(entry, today) {
  return typeof entry.due === "string" && entry.due < today;
}

// What the header counts: still to do, and work rather than a jotting.
function isOutstanding(entry) {
  return entry.status === "needsAction" && entry.type !== "note";
}

function entryRow(entry, today) {
  return {
    kind: "entry",
    id: String(entry.id === undefined || entry.id === null ? "" : entry.id),
    list: String(entry.list === undefined || entry.list === null ? "" : entry.list),
    title: plain(entry.display_title),
    // The title as oxidone gave it: untruncated, unreplaced, and never drawn.
    // `retitle` takes a Display title and re-applies the entry's own type, so
    // an editor seeded from `title` above would save back the elision and the
    // replaced bidi marks that made it safe to render — silently shortening a
    // long title and flattening a mixed-direction one. This is what seeds it.
    rawTitle: String(
      entry.display_title === undefined || entry.display_title === null ? "" : entry.display_title,
    ),
    signifier: signifierFor(entry.type),
    completed: entry.status === "completed",
    overdue: isOverdue(entry, today) && isOutstanding(entry),
    hasNotes: entry.has_notes === true,
    due: typeof entry.due === "string" ? entry.due : "",
    dueLabel: dueLabel(entry.due, today),
  };
}

function headerRow(label, entries, urgent) {
  var count = 0;
  for (var i = 0; i < entries.length; i++) {
    if (isOutstanding(entries[i])) {
      count += 1;
    }
  }
  return { kind: "header", label: label, count: count, urgent: urgent };
}

// One flat array the ListView renders directly. A header is emitted only when
// its group has entries, so a clean morning is one header and an empty day is
// nothing at all.
function buildRows(payload) {
  var overdue = [];
  var today = [];
  for (var i = 0; i < payload.entries.length; i++) {
    var entry = payload.entries[i];
    if (isOverdue(entry, payload.today)) {
      overdue.push(entry);
    } else {
      today.push(entry);
    }
  }

  var rows = [];
  var groups = [
    { label: "Overdue", entries: overdue, urgent: true },
    { label: "Today", entries: today, urgent: false },
  ];
  for (var g = 0; g < groups.length; g++) {
    var group = groups[g];
    if (group.entries.length === 0) {
      continue;
    }
    rows.push(headerRow(group.label, group.entries, group.urgent));
    for (var j = 0; j < group.entries.length; j++) {
      rows.push(entryRow(group.entries[j], payload.today));
    }
  }
  return rows;
}

// A List's own order is Manual order, which the CLI already returns, so rows
// come out in the order they arrived. A Subtask nests one level under its
// parent — never deeper, which the domain guarantees rather than this code.
function buildListRows(payload) {
  // Null-prototype: `parent` is a string oxidone printed, and on a plain object
  // `byParent["__proto__"]` is not a slot you can assign an array to — the
  // push below then throws inside the `rows` binding, which blanks the pane's
  // whole list until something else makes it re-evaluate.
  var byParent = Object.create(null);
  var roots = [];
  for (var i = 0; i < payload.entries.length; i++) {
    var entry = payload.entries[i];
    if (entry.parent) {
      if (!byParent[entry.parent]) {
        byParent[entry.parent] = [];
      }
      byParent[entry.parent].push(entry);
    } else {
      roots.push(entry);
    }
  }

  var rows = [];
  for (var r = 0; r < roots.length; r++) {
    var row = entryRow(roots[r], "");
    row.depth = 0;
    rows.push(row);
    var children = byParent[roots[r].id] || [];
    for (var c = 0; c < children.length; c++) {
      var child = entryRow(children[c], "");
      child.depth = 1;
      rows.push(child);
    }
  }
  return rows;
}

// Which colour role a row's title wears, as a name the Pane maps to a token —
// `src/` holds no QML types, and `Color.menu.text` does not exist out here.
//
// Urgent on a title answers one question: is this entry late. A failed Apply
// and an Armed delete used to colour it too, so a row that was both late and
// failed came out entirely urgent with nothing telling the two apart. Neither
// is a parameter here, and that absence is the rule: both keep urgent on their
// own strings — the failure message and the armed prompt — which say in words
// what happened, where a second red title could only repeat itself.
//
// Pending outranks the rest for the reason Stale wears the same muted: we do
// not know yet.
function titleRole(row, pending) {
  if (pending) {
    return "muted";
  }
  if (row.completed) {
    return "muted";
  }
  if (row.overdue) {
    return "urgent";
  }
  return "text";
}

// Headers are drawn but never landed on, so the keyboard cursor needs the
// indexes it may occupy rather than a range.
function selectableIndexes(rows) {
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind === "entry") {
      out.push(i);
    }
  }
  return out;
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_TITLE: MAX_TITLE,
    MAX_DUE_EXPR: MAX_DUE_EXPR,
    plain: plain,
    hostText: hostText,
    isIsoDate: isIsoDate,
    isDueExpr: isDueExpr,
    signifierFor: signifierFor,
    dueLabel: dueLabel,
    buildRows: buildRows,
    buildListRows: buildListRows,
    selectableIndexes: selectableIndexes,
    titleRole: titleRole,
  };
}
