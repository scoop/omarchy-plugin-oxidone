// `oxidone json apply` reduced to what the Pane needs. Pure functions only —
// no QML, no I/O — so the test runner and the shell load the same file.
//
// The plugin never predicts a result. Every function here either builds the one
// command that goes out or folds the answer that came back into the Snapshot;
// nothing in this file invents an Entry state.

// All eight the contract names. Four take an id and nothing else; the four
// added in slice 4 carry text, which is why they arrived a slice later.
var OPS = [
  "complete",
  "uncomplete",
  "migrate",
  "delete",
  "create",
  "retitle",
  "set_due",
  "clear_due",
];

// Exactly the fields each op's row in the contract names, and in the order the
// contract writes them. The CLI refuses an unknown field rather than ignoring
// it, so a field too many fails the whole call — and one too few is a write
// that means something other than what was asked.
var FIELDS = {
  complete: ["list", "task"],
  uncomplete: ["list", "task"],
  migrate: ["list", "task"],
  delete: ["list", "task"],
  create: ["list", "title"],
  retitle: ["list", "task", "title"],
  set_due: ["list", "task", "due"],
  clear_due: ["list", "task"],
};

// `apply` takes ISO and only ISO — `json due` is what turns a phrase into one.
// A shape check, not a calendar: whether 2026-02-31 is a day is oxidone's
// question, and this only keeps a phrase from reaching a field that cannot hold
// one.
var ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

// A field we did not ask for is a caller bug, and sending it would fail the
// whole call at the CLI. Say so here, where the name is still in hand.
function refuseExtraFields(op, params, wanted) {
  for (var given in params) {
    if (wanted.indexOf(given) < 0) {
      throw new Error("apply: " + op + " takes no `" + given + "`");
    }
  }
}

// One field, checked against what its name means on the wire. Throws rather
// than returns a default: a command missing a field, or carrying a `due` that
// is not a date, means something other than what was asked.
function checkedField(op, field, value) {
  if (typeof value !== "string" || value === "") {
    throw new Error("apply: " + op + " needs a `" + field + "`");
  }
  // A title of nothing but spaces is not a title, and Google would keep it.
  if (field === "title" && value.trim() === "") {
    throw new Error("apply: a title cannot be blank");
  }
  if (field === "due" && !ISO_DATE.test(value)) {
    throw new Error("apply: `due` must be ISO YYYY-MM-DD, not " + value);
  }
  return value;
}

function buildCommand(op, params) {
  if (OPS.indexOf(op) < 0) {
    throw new Error("apply: not an op this release sends: " + String(op));
  }
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new Error("apply: " + op + " needs its fields");
  }
  var wanted = FIELDS[op];
  refuseExtraFields(op, params, wanted);
  var command = { op: op };
  for (var i = 0; i < wanted.length; i++) {
    command[wanted[i]] = checkedField(op, wanted[i], params[wanted[i]]);
  }
  return JSON.stringify(command);
}

// The key a capture's Pending and message are held under. Unique per capture,
// because the Pane's strip stays open for a run: two entries typed in
// succession are two Applies in flight, and a shared key would let the second
// erase the first's report. Derived from a counter rather than the title, so
// the same title twice is still two captures. The colon keeps it out of the
// shape a Google task id has, which is what makes a mix-up impossible rather
// than merely unlikely.
function captureKey(seq) {
  return "capture:" + String(seq);
}

// One queue entry's contribution to the Pending set.
//
// A capture is left out on purpose: its key is `captureKey`'s, never an Entry
// id, so it names no row this set could mute — and its own Pending lives in the
// Service's `captures` map, which a chained capture keeps raised across both
// halves rather than one Apply at a time.
function markPendingKey(pending, entry) {
  if (!entry || entry.capture === true) {
    return;
  }
  if (typeof entry.key !== "string" || entry.key === "") {
    return;
  }
  pending[entry.key] = true;
}

/**
 * Which rows are Pending: every key an Apply is outstanding for — the one in
 * flight, everything queued behind it, and the row whose date is being
 * resolved. Returned as a set keyed by Entry id, which is what the Pane reads.
 *
 * Derived on every call rather than remembered, because a flag written at
 * enqueue and deleted by the answering handler cannot survive two Applies
 * against one row: the first answer clears what the second is still waiting on
 * (issue #5). Nothing here can fall out of step with the queue, because
 * nothing here is kept.
 */
function pendingSet(current, queue, dueRequest) {
  var pending = {};
  if (dueRequest && typeof dueRequest.task === "string" && dueRequest.task !== "") {
    pending[dueRequest.task] = true;
  }
  markPendingKey(pending, current);
  if (Array.isArray(queue)) {
    for (var i = 0; i < queue.length; i++) {
      markPendingKey(pending, queue[i]);
    }
  }
  return pending;
}

// An Entry we can actually fold in: an object with a string id. Anything else
// is refused whole rather than patched in as a hole.
//
// The id and nothing else, deliberately. `rows.js` defends every field it
// draws, so an Echo carrying only an id degrades to a blank row the next poll
// replaces. Checking the rest here would be stricter than the way Entries
// usually arrive — `parseToday` and `parseList` ask only that an entry be an
// object — and a guard tight in one doorway and loose in the other keeps
// nothing out. Tighten both or neither.
function usableEntry(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    typeof value.id === "string" &&
    value.id !== ""
  );
}

// The two parses below open the same way, and `today.js` opens that way twice
// more. They stay apart because both routes out are shut, and both were tried
// against the real engines rather than assumed:
//
// A helper the two files share cannot exist. QML takes one — `.import
// "shared.js" as Shared` resolves and works — but `.import` is a syntax error
// under bun, and `src/` is only worth having while the shell and the test
// runner load the identical file.
//
// The `error` neither catch uses cannot go either. Qt's JS engine rejects the
// optional catch binding as a syntax error, and a file carrying one does not
// load at all — the shell comes up without it.
function parseEcho(stdout) {
  var payload;
  try {
    payload = JSON.parse(stdout);
  } catch (error) {
    return null;
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  return usableEntry(payload.entry) ? payload.entry : null;
}

function parseDeleted(stdout) {
  var payload;
  try {
    payload = JSON.parse(stdout);
  } catch (error) {
    return null;
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  var deleted = payload.deleted;
  if (
    !deleted ||
    typeof deleted !== "object" ||
    Array.isArray(deleted) ||
    typeof deleted.id !== "string" ||
    typeof deleted.list !== "string"
  ) {
    return null;
  }
  return { list: deleted.list, id: deleted.id };
}

// The plugin's voice, chosen by exit code. oxidone's own `message` is serde's
// and Google's — "unknown variant ... at line 1 column 28" is a developer's
// sentence, and a `rejected` message is Google talking to nobody in
// particular. Neither reaches a QML sink; both go to the log.
//
// `context` narrows one code the caller knows more about than the code does:
// resolving a date phrase, exit 2 is `invalid_due` and nothing else, so it can
// say what actually happened instead of blaming the request's shape.
function messageForExit(code, context) {
  if (context === "due" && code === 2) {
    return "that is not a date";
  }
  switch (code) {
    case 0:
      return "done";
    case 2:
      return "oxidone did not understand the request";
    case 3:
      return "oxidone is not authorized any more";
    case 4:
      return "could not reach Google";
    case 5:
      return "Google refused that change";
    case 6:
      return "that entry is gone";
    case 7:
      return "oxidone would not do that";
    case -1:
      return "oxidone did not run";
    default:
      // Exit 1 and anything unforeseen. Deliberately vague rather than wrong:
      // we do not know what happened, and saying so is the honest answer.
      return "the change did not go through";
  }
}

// A Today capture is two Applies — `create`, then `set_due` with the Snapshot's
// own date — and only the second can fail on its own. The entry is real and the
// person should be told where, since an undated entry is in no Today to be
// found in. The title is the caller's to sanitize before it gets here.
function halfCaptureMessage(listTitle) {
  var where = typeof listTitle === "string" && listTitle !== "" ? " in " + listTitle : "";
  return "created, but could not be dated — it is undated" + where;
}

// A new array every time. QML re-evaluates a binding on a new reference, not on
// a mutation, so patching in place would change the data and update nothing.
function patchEntries(entries, echo) {
  if (!Array.isArray(entries) || !usableEntry(echo)) {
    return entries;
  }
  var out = [];
  for (var i = 0; i < entries.length; i++) {
    out.push(entries[i] && entries[i].id === echo.id ? echo : entries[i]);
  }
  return out;
}

// An Entry the Snapshot does not have yet, put where Google puts it: at the
// top. Not a guess — a new Task goes to the head of its List, which is what the
// Echo's own `position` will say on the next read. An id already present is
// patched instead, so folding twice cannot double a row.
function insertEntry(entries, echo) {
  if (!Array.isArray(entries) || !usableEntry(echo)) {
    return entries;
  }
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] && entries[i].id === echo.id) {
      return patchEntries(entries, echo);
    }
  }
  return [echo].concat(entries);
}

// A poll supersedes only the failures it actually describes. An Entry the
// answer does not mention — a List-scope row with no Today date, say — keeps
// its message until something speaks to that row.
function retainErrorsAbsentFrom(errors, entries) {
  if (!errors || typeof errors !== "object" || Array.isArray(errors)) {
    return {};
  }
  if (!Array.isArray(entries)) {
    // Nothing to compare against: safest is to change nothing, since we
    // cannot tell which failures this answer speaks to.
    var copy = {};
    for (var key in errors) {
      copy[key] = errors[key];
    }
    return copy;
  }
  var seen = {};
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] && typeof entries[i].id === "string") {
      seen[entries[i].id] = true;
    }
  }
  var out = {};
  for (var id in errors) {
    if (!seen[id]) {
      out[id] = errors[id];
    }
  }
  return out;
}

function removeEntry(entries, id) {
  if (!Array.isArray(entries) || typeof id !== "string" || id === "") {
    return entries;
  }
  var out = [];
  for (var i = 0; i < entries.length; i++) {
    if (!entries[i] || entries[i].id !== id) {
      out.push(entries[i]);
    }
  }
  return out;
}

if (typeof module !== "undefined") {
  module.exports = {
    OPS: OPS,
    FIELDS: FIELDS,
    buildCommand: buildCommand,
    captureKey: captureKey,
    pendingSet: pendingSet,
    parseEcho: parseEcho,
    parseDeleted: parseDeleted,
    messageForExit: messageForExit,
    halfCaptureMessage: halfCaptureMessage,
    patchEntries: patchEntries,
    insertEntry: insertEntry,
    removeEntry: removeEntry,
    retainErrorsAbsentFrom: retainErrorsAbsentFrom,
  };
}
