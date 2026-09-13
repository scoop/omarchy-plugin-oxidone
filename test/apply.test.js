import { test, expect } from "bun:test";
import {
  OPS,
  FIELDS,
  buildCommand,
  captureKey,
  parseEcho,
  parseDeleted,
  messageForExit,
  halfCaptureMessage,
  patchEntries,
  insertEntry,
  removeEntry,
  retainErrorsAbsentFrom,
} from "../src/apply.js";

const entry = (over) =>
  Object.assign(
    {
      id: "t1",
      list: "L",
      parent: null,
      title: "Thing",
      display_title: "Thing",
      type: "task",
      has_notes: false,
      due: "2026-09-12",
      status: "needsAction",
      completed_at: null,
      position: "01",
    },
    over || {},
  );

test("OPS is exactly the eight the contract names", () => {
  expect(OPS.slice().sort()).toEqual([
    "clear_due",
    "complete",
    "create",
    "delete",
    "migrate",
    "retitle",
    "set_due",
    "uncomplete",
  ]);
});

test("every op names the fields its row in the contract names", () => {
  expect(FIELDS).toEqual({
    complete: ["list", "task"],
    uncomplete: ["list", "task"],
    migrate: ["list", "task"],
    delete: ["list", "task"],
    create: ["list", "title"],
    retitle: ["list", "task", "title"],
    set_due: ["list", "task", "due"],
    clear_due: ["list", "task"],
  });
  expect(Object.keys(FIELDS).sort()).toEqual(OPS.slice().sort());
});

test("buildCommand emits one command with only the contract's fields", () => {
  expect(JSON.parse(buildCommand("complete", { list: "L", task: "T" }))).toEqual({
    op: "complete",
    list: "L",
    task: "T",
  });
  expect(JSON.parse(buildCommand("create", { list: "L", title: "Buy milk" }))).toEqual({
    op: "create",
    list: "L",
    title: "Buy milk",
  });
  expect(
    JSON.parse(buildCommand("retitle", { list: "L", task: "T", title: "Daily sync" })),
  ).toEqual({ op: "retitle", list: "L", task: "T", title: "Daily sync" });
  expect(JSON.parse(buildCommand("set_due", { list: "L", task: "T", due: "2026-12-25" }))).toEqual({
    op: "set_due",
    list: "L",
    task: "T",
    due: "2026-12-25",
  });
  expect(JSON.parse(buildCommand("clear_due", { list: "L", task: "T" }))).toEqual({
    op: "clear_due",
    list: "L",
    task: "T",
  });
});

test("buildCommand refuses an op that does not ship", () => {
  expect(() => buildCommand("rename", { list: "L", task: "T" })).toThrow();
  expect(() => buildCommand("", { list: "L", task: "T" })).toThrow();
});

test("buildCommand refuses an empty list or task id", () => {
  expect(() => buildCommand("complete", { list: "", task: "T" })).toThrow();
  expect(() => buildCommand("complete", { list: "L", task: "" })).toThrow();
  expect(() => buildCommand("complete", { list: "L" })).toThrow();
  expect(() => buildCommand("complete", null)).toThrow();
});

test("buildCommand refuses a field the op does not take", () => {
  // The CLI refuses an unknown field rather than ignoring it, so one too many
  // fails the whole call. Better to be told here, where the name is in hand.
  expect(() => buildCommand("create", { list: "L", title: "x", task: "T" })).toThrow();
  expect(() => buildCommand("complete", { list: "L", task: "T", due: "2026-12-25" })).toThrow();
  expect(() => buildCommand("clear_due", { list: "L", task: "T", due: "2026-12-25" })).toThrow();
});

test("buildCommand refuses a title that is empty or nothing but space", () => {
  expect(() => buildCommand("create", { list: "L", title: "" })).toThrow();
  expect(() => buildCommand("create", { list: "L", title: "   " })).toThrow();
  expect(() => buildCommand("retitle", { list: "L", task: "T", title: "\t \n" })).toThrow();
});

test("buildCommand sends a title verbatim, signifier and all", () => {
  // `create` writes the title as typed — a leading glyph making an Event is
  // oxidone's rule, not ours to apply or undo. Only a blank one is refused.
  const command = JSON.parse(buildCommand("create", { list: "L", title: "○ Standup" }));
  expect(command.title).toBe("○ Standup");
});

test("buildCommand refuses a due that is not ISO", () => {
  // `apply` takes ISO and only ISO; `json due` is what turns a phrase into one.
  for (const due of [
    "tomorrow",
    "+3d",
    "25",
    "2026-7-25",
    "26-12-25",
    "2026-12-25T00:00:00Z",
    "",
  ]) {
    expect(() => buildCommand("set_due", { list: "L", task: "T", due })).toThrow();
  }
  expect(() => buildCommand("set_due", { list: "L", task: "T", due: "2026-12-25" })).not.toThrow();
});

test("captureKey is unique per capture and shaped unlike a task id", () => {
  // Two entries typed in one run are two Applies in flight. A key they shared
  // would let the second erase the first's report.
  const keys = [1, 2, 3, 4].map(captureKey);
  expect(new Set(keys).size).toBe(4);
  // Google's task ids are base64url; the colon is what keeps a capture key from
  // ever being mistaken for one.
  expect(captureKey(1)).toContain(":");
});

test("parseEcho returns the entry", () => {
  expect(parseEcho(JSON.stringify({ entry: entry({ status: "completed" }) })).status).toBe(
    "completed",
  );
});

test("parseEcho refuses anything that is not a usable entry", () => {
  expect(parseEcho("")).toBe(null);
  expect(parseEcho("not json")).toBe(null);
  expect(parseEcho(JSON.stringify({ entry: null }))).toBe(null);
  expect(parseEcho(JSON.stringify({ entry: [] }))).toBe(null);
  expect(parseEcho(JSON.stringify({ entry: { id: 7 } }))).toBe(null);
  expect(parseEcho(JSON.stringify({ deleted: { list: "L", id: "T" } }))).toBe(null);
});

test("parseDeleted returns what went", () => {
  expect(parseDeleted(JSON.stringify({ deleted: { list: "L", id: "T" } }))).toEqual({
    list: "L",
    id: "T",
  });
  expect(parseDeleted(JSON.stringify({ entry: entry() }))).toBe(null);
  expect(parseDeleted("{")).toBe(null);
});

test("messageForExit speaks in our words, never oxidone's", () => {
  expect(messageForExit(3)).toBe("oxidone is not authorized any more");
  expect(messageForExit(4)).toBe("could not reach Google");
  expect(messageForExit(5)).toBe("Google refused that change");
  expect(messageForExit(6)).toBe("that entry is gone");
  expect(messageForExit(7)).toBe("oxidone would not do that");
  expect(messageForExit(-1)).toBe("oxidone did not run");
  // Every code returns a non-empty sentence; a blank message would render an
  // empty error row that says a write failed without saying anything.
  [-1, 0, 1, 2, 3, 4, 5, 6, 7, 99].forEach((code) => {
    expect(messageForExit(code).length).toBeGreaterThan(0);
  });
});

test("patchEntries replaces by id and preserves order", () => {
  const before = [entry({ id: "a" }), entry({ id: "b" }), entry({ id: "c" })];
  const after = patchEntries(before, entry({ id: "b", status: "completed" }));
  expect(after.map((e) => e.id)).toEqual(["a", "b", "c"]);
  expect(after[1].status).toBe("completed");
  // The input array is not mutated: QML bindings only re-evaluate on a new
  // reference, and a mutated-in-place array would update nothing.
  expect(before[1].status).toBe("needsAction");
  expect(after).not.toBe(before);
});

test("patchEntries leaves an unknown id alone", () => {
  const before = [entry({ id: "a" })];
  expect(patchEntries(before, entry({ id: "zzz" })).map((e) => e.id)).toEqual(["a"]);
});

test("removeEntry drops exactly one id", () => {
  const before = [entry({ id: "a" }), entry({ id: "b" })];
  expect(removeEntry(before, "a").map((e) => e.id)).toEqual(["b"]);
  expect(removeEntry(before, "zzz").map((e) => e.id)).toEqual(["a", "b"]);
  expect(before.length).toBe(2);
});

test("retainErrorsAbsentFrom clears an id the answer mentions", () => {
  const errors = { a: "could not reach Google", b: "that entry is gone" };
  const result = retainErrorsAbsentFrom(errors, [entry({ id: "a" })]);
  expect(result).toEqual({ b: "that entry is gone" });
});

test("retainErrorsAbsentFrom keeps an id the answer does not mention", () => {
  const errors = { a: "could not reach Google" };
  // A List-scope row with no Today date: a Today poll never names it.
  const result = retainErrorsAbsentFrom(errors, [entry({ id: "zzz" })]);
  expect(result).toEqual({ a: "could not reach Google" });
});

test("retainErrorsAbsentFrom keeps everything on an empty answer", () => {
  const errors = { a: "could not reach Google", b: "that entry is gone" };
  expect(retainErrorsAbsentFrom(errors, [])).toEqual(errors);
});

test("retainErrorsAbsentFrom does not throw on a non-array entries", () => {
  const errors = { a: "could not reach Google" };
  expect(() => retainErrorsAbsentFrom(errors, null)).not.toThrow();
  expect(() => retainErrorsAbsentFrom(errors, undefined)).not.toThrow();
  expect(() => retainErrorsAbsentFrom(errors, "nope")).not.toThrow();
  expect(retainErrorsAbsentFrom(errors, null)).toEqual(errors);
});

test("retainErrorsAbsentFrom does not mutate the input object", () => {
  const errors = { a: "could not reach Google", b: "that entry is gone" };
  const snapshot = Object.assign({}, errors);
  retainErrorsAbsentFrom(errors, [entry({ id: "a" })]);
  expect(errors).toEqual(snapshot);
});

test("messageForExit says what exit 2 means when a date was being resolved", () => {
  // `json due` exits 2 as `invalid_due` and nothing else, so it can say what
  // actually happened rather than blaming the request's shape.
  expect(messageForExit(2, "due")).toBe("that is not a date");
  expect(messageForExit(2)).toBe("oxidone did not understand the request");
  expect(messageForExit(2, "")).toBe("oxidone did not understand the request");
});

test("the due context narrows exit 2 and nothing else", () => {
  for (const code of [0, 1, 3, 4, 5, 6, 7, -1, 99]) {
    expect(messageForExit(code, "due")).toBe(messageForExit(code));
  }
});

test("halfCaptureMessage names where the entry actually is", () => {
  expect(halfCaptureMessage("Inbox")).toContain("Inbox");
  expect(halfCaptureMessage("Inbox")).toContain("undated");
  // A list we have no title for still gets a sentence, just a vaguer one.
  expect(halfCaptureMessage("")).toContain("undated");
  expect(halfCaptureMessage(null)).toContain("undated");
});

test("insertEntry puts a new entry where Google puts it", () => {
  const existing = [entry({ id: "a" }), entry({ id: "b" })];
  const out = insertEntry(existing, entry({ id: "new" }));
  expect(out.map((e) => e.id)).toEqual(["new", "a", "b"]);
  // A new array, because a binding re-evaluates on a new reference.
  expect(out).not.toBe(existing);
  expect(existing.length).toBe(2);
});

test("insertEntry patches rather than doubling an entry already there", () => {
  const existing = [entry({ id: "a", display_title: "old" }), entry({ id: "b" })];
  const out = insertEntry(existing, entry({ id: "a", display_title: "new" }));
  expect(out.length).toBe(2);
  expect(out[0].display_title).toBe("new");
});

test("insertEntry refuses anything that is not a usable entry", () => {
  const existing = [entry({ id: "a" })];
  for (const bad of [null, undefined, 42, [], {}, { id: "" }, { id: 7 }]) {
    expect(insertEntry(existing, bad)).toBe(existing);
  }
  expect(insertEntry(null, entry({}))).toBe(null);
});
