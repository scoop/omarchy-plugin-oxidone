import { test, expect } from "bun:test";
import {
  OPS,
  buildCommand,
  parseEcho,
  parseDeleted,
  messageForExit,
  patchEntries,
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

test("OPS is exactly the four that ship", () => {
  expect(OPS.slice().sort()).toEqual(["complete", "delete", "migrate", "uncomplete"]);
});

test("buildCommand emits one command with only the contract's fields", () => {
  expect(JSON.parse(buildCommand("complete", "L", "T"))).toEqual({
    op: "complete",
    list: "L",
    task: "T",
  });
});

test("buildCommand refuses an op that does not ship", () => {
  expect(() => buildCommand("retitle", "L", "T")).toThrow();
  expect(() => buildCommand("", "L", "T")).toThrow();
});

test("buildCommand refuses an empty list or task id", () => {
  expect(() => buildCommand("complete", "", "T")).toThrow();
  expect(() => buildCommand("complete", "L", "")).toThrow();
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
