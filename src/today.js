// `oxidone json today` read into what the bar needs. Pure functions only — no
// QML, no I/O — so the test runner and the shell load the same file.
//
// Slice 1 counts only what is outstanding, so the CLI's status-blindness does
// not reach the bar: a completed entry is excluded by status whatever its date.
// The completed-today filter oxidone#135 calls for arrives with the Pane, which
// is the first surface that renders a Completed row at all.

// A byte ceiling bounds how big the answer is, not what shape it has: a quarter
// of a megabyte of JSON is still tens of thousands of objects. Cardinality and
// per-entry type are checked here so a malformed answer is refused whole rather
// than counted into a number the bar then displays as fact.
var MAX_ENTRIES = 5000;

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
  if (payload.entries.length > MAX_ENTRIES) {
    throw new Error("today: more than " + MAX_ENTRIES + " entries");
  }
  for (var i = 0; i < payload.entries.length; i++) {
    var entry = payload.entries[i];
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error("today: entry " + i + " is not an object");
    }
  }
  return payload;
}

// `json tasks --list` answers with a list id where `today` answers with a
// date. Same bounds, same entry checks, different required field.
function parseList(stdout) {
  var payload = JSON.parse(stdout);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("tasks: expected an object");
  }
  if (typeof payload.list !== "string") {
    throw new Error("tasks: no `list` id");
  }
  if (!Array.isArray(payload.entries)) {
    throw new Error("tasks: no `entries` array");
  }
  if (payload.entries.length > MAX_ENTRIES) {
    throw new Error("tasks: more than " + MAX_ENTRIES + " entries");
  }
  for (var i = 0; i < payload.entries.length; i++) {
    var entry = payload.entries[i];
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error("tasks: entry " + i + " is not an object");
    }
  }
  return payload;
}

// The selector's options. This is the one answer a QML binding dereferences
// field by field (`Pane.qml`'s `scopeOptions`), and a TypeError there takes the
// whole binding down with it — the selector would lose even its "Today" row and
// every h/l would throw. Two hundred lists is already far past what a Google
// account carries.
var MAX_LISTS = 200;

// Refused whole — `null`, never a partial — when the envelope is wrong, so a
// truncated or foreign answer cannot pass for a shorter list of lists. Inside a
// sound envelope an entry that is not an { id, title } pair is dropped: it is
// not something the selector can name or fetch.
function parseLists(stdout) {
  var payload = JSON.parse(stdout);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  if (!Array.isArray(payload.lists)) {
    return null;
  }
  if (payload.lists.length > MAX_LISTS) {
    return null;
  }
  var out = [];
  for (var i = 0; i < payload.lists.length; i++) {
    var list = payload.lists[i];
    if (!list || typeof list !== "object" || Array.isArray(list)) {
      continue;
    }
    if (typeof list.id !== "string" || list.id === "" || typeof list.title !== "string") {
      continue;
    }
    out.push(list);
  }
  return out;
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
    MAX_ENTRIES: MAX_ENTRIES,
    MAX_LISTS: MAX_LISTS,
    parseToday: parseToday,
    parseList: parseList,
    parseLists: parseLists,
    outstandingCount: outstandingCount,
    hasOverdue: hasOverdue,
  };
}
