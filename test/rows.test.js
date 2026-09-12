import { test, expect } from "bun:test";
import {
  plain,
  buildRows,
  signifierFor,
  dueLabel,
  selectableIndexes,
  MAX_TITLE,
} from "../src/rows.js";

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

test("control and bidi characters are replaced, not dropped", () => {
  // Dropping them would join two words into one; the row must stay readable
  // and must not be reorderable by its own content. Escapes, not literals:
  // a raw control byte in a source file stops the marketplace scanner.
  expect(plain("a\u0007b")).toBe("a b");
  expect(plain("a\u202Eb")).toBe("a b");
  expect(plain("a\tb")).toBe("a b");
  expect(plain("a\u0000b")).toBe("a b");
  expect(plain("plain title")).toBe("plain title");
});

test("a title longer than the cap is elided rather than passed through", () => {
  const long = "x".repeat(MAX_TITLE + 50);
  const out = plain(long);
  expect(out.length).toBe(MAX_TITLE);
  expect(out.endsWith("…")).toBe(true);
});

test("a missing title is an empty string, not the word undefined", () => {
  expect(plain(undefined)).toBe("");
  expect(plain(null)).toBe("");
});

test("an entry type carries its signifier, a Task carries none", () => {
  expect(signifierFor("event")).toBe("○");
  expect(signifierFor("note")).toBe("—");
  expect(signifierFor("task")).toBe("");
  expect(signifierFor("something-new")).toBe("");
});

test("a due date is labelled only when it is not today", () => {
  expect(dueLabel("2026-07-20", "2026-07-20")).toBe("");
  expect(dueLabel("2026-07-18", "2026-07-20")).toBe("07-18");
  expect(dueLabel(null, "2026-07-20")).toBe("");
});

test("entries split into an Overdue group and a Today group, in that order", () => {
  const rows = buildRows(payload([entry({}), entry({ id: "t2", due: "2026-07-18" })]));
  expect(rows.map((r) => r.kind)).toEqual(["header", "entry", "header", "entry"]);
  expect(rows[0].label).toBe("Overdue");
  expect(rows[0].urgent).toBe(true);
  expect(rows[1].id).toBe("t2");
  expect(rows[2].label).toBe("Today");
  expect(rows[3].id).toBe("t1");
});

test("a group with no entries prints no header", () => {
  const rows = buildRows(payload([entry({})]));
  expect(rows.map((r) => r.kind)).toEqual(["header", "entry"]);
  expect(rows[0].label).toBe("Today");
});

test("an empty day is an empty list, not a bare header", () => {
  expect(buildRows(payload([]))).toEqual([]);
});

test("the header counts what is outstanding, not what is drawn", () => {
  // Grouping is status-blind so the group stays a contiguous run, but the
  // count answers the migration question: what is left to move.
  const rows = buildRows(
    payload([
      entry({ due: "2026-07-18" }),
      entry({ id: "t2", due: "2026-07-18", status: "completed" }),
    ]),
  );
  expect(rows[0].label).toBe("Overdue");
  expect(rows[0].count).toBe(1);
  expect(rows.filter((r) => r.kind === "entry").length).toBe(2);
});

test("a Note is drawn but never counted", () => {
  const rows = buildRows(payload([entry({ type: "note" })]));
  expect(rows[0].count).toBe(0);
  expect(rows[1].signifier).toBe("—");
});

test("an entry row carries what the delegate needs and nothing more", () => {
  const row = buildRows(payload([entry({ has_notes: true })]))[1];
  expect(Object.keys(row).sort()).toEqual([
    "completed",
    "due",
    "dueLabel",
    "hasNotes",
    "id",
    "kind",
    "list",
    "overdue",
    "signifier",
    "title",
  ]);
});

test("only entry rows are selectable", () => {
  const rows = buildRows(payload([entry({}), entry({ id: "t2", due: "2026-07-18" })]));
  expect(selectableIndexes(rows)).toEqual([1, 3]);
});
