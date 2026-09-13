// `oxidone json apply` reduced to what the Pane needs. Pure functions only —
// no QML, no I/O — so the test runner and the shell load the same file.
//
// The plugin never predicts a result. Every function here either builds the one
// command that goes out or folds the answer that came back into the Snapshot;
// nothing in this file invents an Entry state.

// The four that ship in this slice. `create`, `retitle`, `set_due` and
// `clear_due` all need a text field and are slice 4 — an op absent from this
// list is refused by buildCommand rather than sent and rejected by the CLI.
var OPS = ["complete", "uncomplete", "migrate", "delete"];

function buildCommand(op, listId, taskId) {
  if (OPS.indexOf(op) < 0) {
    throw new Error("apply: not an op this release sends: " + String(op));
  }
  if (typeof listId !== "string" || listId === "") {
    throw new Error("apply: empty list id");
  }
  if (typeof taskId !== "string" || taskId === "") {
    throw new Error("apply: empty task id");
  }
  // Exactly the contract's fields and no others: the CLI refuses an unknown
  // field rather than ignoring it, so anything extra here fails the whole call.
  return JSON.stringify({ op: op, list: listId, task: taskId });
}

// An Entry we can actually fold in: an object with a string id. Anything else
// is refused whole rather than patched in as a hole.
function usableEntry(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    typeof value.id === "string" &&
    value.id !== ""
  );
}

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
function messageForExit(code) {
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
    buildCommand: buildCommand,
    parseEcho: parseEcho,
    parseDeleted: parseDeleted,
    messageForExit: messageForExit,
    patchEntries: patchEntries,
    removeEntry: removeEntry,
  };
}
