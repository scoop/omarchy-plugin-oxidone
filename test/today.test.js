import { test, expect } from "bun:test";
import { parseToday, outstandingCount, hasOverdue, MAX_ENTRIES } from "../src/today.js";

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
      due: "2026-07-20",
      status: "needsAction",
      completed_at: null,
      position: "00",
    },
    over,
  );

const payload = (entries) => ({ today: "2026-07-20", entries });

test("a well-formed answer parses to its date and entries", () => {
  const parsed = parseToday(JSON.stringify(payload([entry({})])));
  expect(parsed.today).toBe("2026-07-20");
  expect(parsed.entries.length).toBe(1);
});

test("an answer that is not an object is refused rather than guessed at", () => {
  expect(() => parseToday("[]")).toThrow();
  expect(() => parseToday('{"entries": []}')).toThrow();
  expect(() => parseToday('{"today": "2026-07-20"}')).toThrow();
});

test("an answer with more entries than the cap is refused whole, not truncated", () => {
  const many = { today: "2026-07-20", entries: new Array(MAX_ENTRIES + 1).fill(entry({})) };
  expect(() => parseToday(JSON.stringify(many))).toThrow();
  const atCap = { today: "2026-07-20", entries: new Array(MAX_ENTRIES).fill(entry({})) };
  expect(parseToday(JSON.stringify(atCap)).entries.length).toBe(MAX_ENTRIES);
});

test("an entry that is not an object is refused rather than counted", () => {
  for (const bad of [null, 42, "x", []]) {
    expect(() => parseToday(JSON.stringify({ today: "2026-07-20", entries: [bad] }))).toThrow();
  }
});

test("the count is outstanding work, so a completed entry is not in it", () => {
  expect(outstandingCount(payload([entry({}), entry({ id: "t2", status: "completed" })]))).toBe(1);
});

test("an Event counts as work to come, a Note does not", () => {
  const entries = [entry({ type: "event" }), entry({ id: "t2", type: "note" })];
  expect(outstandingCount(payload(entries))).toBe(1);
});

test("overdue is outstanding and dated strictly before today", () => {
  expect(hasOverdue(payload([entry({})]))).toBe(false);
  expect(hasOverdue(payload([entry({ due: "2026-07-19" })]))).toBe(true);
  expect(hasOverdue(payload([entry({ due: "2026-07-19", status: "completed" })]))).toBe(false);
  expect(hasOverdue(payload([entry({ due: null })]))).toBe(false);
});
