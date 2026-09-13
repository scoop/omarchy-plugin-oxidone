import { test, expect } from "bun:test";
import {
  plain,
  buildRows,
  buildListRows,
  signifierFor,
  dueLabel,
  selectableIndexes,
  titleRole,
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
    "rawTitle",
    "signifier",
    "title",
  ]);
});

test("rawTitle is the title as oxidone gave it, drawn title or not", () => {
  const long = "x".repeat(MAX_TITLE + 40);
  const row = buildRows(payload([entry({ display_title: long })]))[1];
  // `title` is elided so a row stays a row; `rawTitle` is what a rename must
  // send back, and an elision saved as the new name is a title destroyed.
  expect(row.title.endsWith("\u2026")).toBe(true);
  expect(row.title.length).toBe(MAX_TITLE);
  expect(row.rawTitle).toBe(long);
});

test("rawTitle keeps the marks plain() has to replace to render safely", () => {
  const bidi = "\u202ekcatta\u202c";
  const row = buildRows(payload([entry({ display_title: bidi })]))[1];
  expect(row.title).not.toBe(bidi);
  expect(row.rawTitle).toBe(bidi);
});

test("rawTitle is a string even when the entry has no display title", () => {
  expect(buildRows(payload([entry({ display_title: null })]))[1].rawTitle).toBe("");
});

test("only entry rows are selectable", () => {
  const rows = buildRows(payload([entry({}), entry({ id: "t2", due: "2026-07-18" })]));
  expect(selectableIndexes(rows)).toEqual([1, 3]);
});

test("line and paragraph separators are replaced like any other break", () => {
  const ch = String.fromCharCode;
  expect(plain("a" + ch(0x2028) + "b")).toBe("a b");
  expect(plain("a" + ch(0x2029) + "b")).toBe("a b");
});

test("a list's rows keep the CLI's order and nest one level", () => {
  const rows = buildListRows({
    list: "L",
    entries: [
      entry({ id: "p1", due: null }),
      entry({ id: "c1", parent: "p1", due: null }),
      entry({ id: "p2", due: null }),
    ],
  });
  expect(rows.map((r) => r.id)).toEqual(["p1", "c1", "p2"]);
  expect(rows.map((r) => r.depth)).toEqual([0, 1, 0]);
});

test("a list row is never overdue, because a list is not a day", () => {
  const rows = buildListRows({ list: "L", entries: [entry({ due: "2020-01-01" })] });
  expect(rows[0].overdue).toBe(false);
  expect(rows[0].dueLabel).toBe("01-01");
});

test("a title cut mid-emoji does not leave half a character behind", () => {
  const out = plain("x".repeat(MAX_TITLE - 2) + String.fromCodePoint(0x1f600) + "y");
  expect(out.length).toBeLessThanOrEqual(MAX_TITLE);
  expect(out.endsWith("…")).toBe(true);
  for (let i = 0; i < out.length; i++) {
    const c = out.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = out.charCodeAt(i + 1);
      expect(next >= 0xdc00 && next <= 0xdfff).toBe(true);
    }
    if (c >= 0xdc00 && c <= 0xdfff) {
      const prev = out.charCodeAt(i - 1);
      expect(prev >= 0xd800 && prev <= 0xdbff).toBe(true);
    }
  }
});

const entriesOf = (rows) =>
  Object.fromEntries(rows.filter((r) => r.kind === "entry").map((r) => [r.id, r]));

const titleRows = () =>
  entriesOf(
    buildRows(
      payload([
        entry({ id: "late", due: "2026-07-01" }),
        entry({ id: "now" }),
        entry({ id: "done", status: "completed" }),
      ]),
    ),
  );

test("a title's colour answers one question: is this entry late", () => {
  const rows = titleRows();
  expect(titleRole(rows.late, false)).toBe("urgent");
  expect(titleRole(rows.now, false)).toBe("text");
  expect(titleRole(rows.done, false)).toBe("muted");
});

test("a pending row is muted whatever else is true of it", () => {
  // The same muted the Snapshot wears when it cannot be trusted, and it
  // outranks overdue for the same reason: we do not know yet.
  const rows = titleRows();
  expect(titleRole(rows.now, true)).toBe("muted");
  expect(titleRole(rows.late, true)).toBe("muted");
});

test("a failed or armed row's title still answers only overdue-ness", () => {
  // Issue #6: urgent used to mean both "late" and "this did not go through",
  // so a row that was both was entirely one colour. Neither state is an input
  // here — parking them on the row proves the function cannot read them, and
  // the failure message and the armed prompt keep urgent of their own.
  const rows = titleRows();
  const failed = Object.assign({}, rows.now, { failure: "oxidone did not answer" });
  const failedAndLate = Object.assign({}, rows.late, { failure: "oxidone did not answer" });
  const armed = Object.assign({}, rows.now, { armed: true });
  const armedAndLate = Object.assign({}, rows.late, { armed: true });
  expect(titleRole(failed, false)).toBe("text");
  expect(titleRole(failedAndLate, false)).toBe("urgent");
  expect(titleRole(armed, false)).toBe("text");
  expect(titleRole(armedAndLate, false)).toBe("urgent");
});
