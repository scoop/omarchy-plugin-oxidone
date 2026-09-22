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

// The process's byte ceiling bounds how much of an answer arrives; it bounds no
// single field inside one. A quarter of a megabyte spent on one title is a
// sound-looking envelope whose one entry is then carried by a row, by an editor
// seed and by an `apply` payload alike. Google's own limit for a task title is
// 1024 characters, so nothing an account can hold comes near this.
//
// Refused whole rather than truncated, for the reason `rawTitle` exists: a
// title shortened here and saved back by `retitle` is a silent edit to
// someone's data, and a shortened id is a write aimed at the wrong entry.
var MAX_FIELD = 4096;

// Every field of an entry this plugin reads as a string. `parent` and `id` key
// maps, `display_title` seeds the rename editor, `due` seeds the date editor
// and can reach argv, `list` and `title` are carried into `apply` payloads.
var BOUNDED_FIELDS = ["id", "list", "parent", "title", "display_title", "due"];

// The name of the first field past the ceiling, or "" when the entry is sound.
function oversizedField(entry) {
  for (var f = 0; f < BOUNDED_FIELDS.length; f++) {
    var name = BOUNDED_FIELDS[f];
    if (typeof entry[name] === "string" && entry[name].length > MAX_FIELD) {
      return name;
    }
  }
  return "";
}

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
    var oversized = oversizedField(entry);
    if (oversized !== "") {
      throw new Error("today: entry " + i + " has an oversized `" + oversized + "`");
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
    var oversized = oversizedField(entry);
    if (oversized !== "") {
      throw new Error("tasks: entry " + i + " has an oversized `" + oversized + "`");
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

// One { id, title } pair the selector can name and fetch. Anything else is
// dropped: a list it cannot name is not one it could put on screen.
function usableList(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    typeof value.id === "string" &&
    value.id !== "" &&
    value.id.length <= MAX_FIELD &&
    typeof value.title === "string" &&
    // Dropped rather than refused, like every other unusable list: a title this
    // long is not one the selector could put on screen anyway.
    value.title.length <= MAX_FIELD
  );
}

// `default_list` is the concrete id `@default` resolves to, and it is what a
// capture in Today scope targets — Today being no List, a capture there needs
// one. Kept only when it names a List we also kept: the Pane says where a
// capture is going, and it cannot name a List it has no title for.
function resolveDefaultList(wanted, lists) {
  if (typeof wanted !== "string") {
    return "";
  }
  for (var i = 0; i < lists.length; i++) {
    if (lists[i].id === wanted) {
      return wanted;
    }
  }
  return "";
}

// Refused whole — `null`, never a partial — when the envelope is wrong, so a
// truncated or foreign answer cannot pass for a shorter list of lists. Inside a
// sound envelope an entry that is not an { id, title } pair is dropped: it is
// not something the selector can name or fetch.
function parseLists(stdout) {
  var payload = JSON.parse(stdout);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  if (!Array.isArray(payload.lists) || payload.lists.length > MAX_LISTS) {
    return null;
  }
  var out = [];
  for (var i = 0; i < payload.lists.length; i++) {
    if (usableList(payload.lists[i])) {
      out.push(payload.lists[i]);
    }
  }
  return { lists: out, default_list: resolveDefaultList(payload.default_list, out) };
}

// `oxidone json due <expr>` resolves a date phrase — the same vocabulary the
// TUI's `d` accepts — without credentials or a network. The ISO shape is
// checked here rather than trusted, because it is the one thing `apply set_due`
// will not tolerate being wrong: a refusal we can report beats a write that
// fails at Google.
var ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function parseDue(stdout) {
  var payload;
  try {
    payload = JSON.parse(stdout);
  } catch (error) {
    return null;
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  return typeof payload.due === "string" && ISO_DATE.test(payload.due) ? payload.due : null;
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
    MAX_FIELD: MAX_FIELD,
    parseToday: parseToday,
    parseList: parseList,
    parseLists: parseLists,
    parseDue: parseDue,
    outstandingCount: outstandingCount,
    hasOverdue: hasOverdue,
  };
}
