// `oxidone json today` read into what the bar needs. Pure functions only — no
// QML, no I/O — so the test runner and the shell load the same file.
//
// Slice 1 counts only what is outstanding, so the CLI's status-blindness does
// not reach the bar: a completed entry is excluded by status whatever its date.
// The completed-today filter oxidone#135 calls for arrives with the Pane, which
// is the first surface that renders a Completed row at all.

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
  return payload;
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
    parseToday: parseToday,
    outstandingCount: outstandingCount,
    hasOverdue: hasOverdue,
  };
}
