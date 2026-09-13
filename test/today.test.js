import { test, expect } from "bun:test";
import {
  parseToday,
  parseList,
  parseLists,
  parseDue,
  outstandingCount,
  hasOverdue,
  MAX_ENTRIES,
  MAX_LISTS,
} from "../src/today.js";

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

test("a well-formed lists answer parses to its lists", () => {
  const parsed = parseLists(JSON.stringify({ lists: [{ id: "L1", title: "Errands" }] }));
  expect(parsed.lists.length).toBe(1);
  expect(parsed.lists[0].id).toBe("L1");
  expect(parsed.lists[0].title).toBe("Errands");
});

test("a lists answer that is not an object is refused whole rather than guessed at", () => {
  expect(parseLists("[]")).toBe(null);
  expect(parseLists("null")).toBe(null);
  expect(parseLists("{}")).toBe(null);
  expect(parseLists('{"lists": {}}')).toBe(null);
  expect(parseLists('{"lists": "Work"}')).toBe(null);
});

test("a lists answer with more lists than the cap is refused whole, not truncated", () => {
  const one = { id: "L1", title: "Errands" };
  const many = { lists: new Array(MAX_LISTS + 1).fill(one) };
  expect(parseLists(JSON.stringify(many))).toBe(null);
  const atCap = { lists: new Array(MAX_LISTS).fill(one) };
  expect(parseLists(JSON.stringify(atCap)).lists.length).toBe(MAX_LISTS);
});

test("a list entry the selector could not name or fetch is dropped, not carried", () => {
  // `{"lists":[null]}` used to reach the Pane's scopeOptions binding and take
  // it down with a TypeError, losing even the Today option.
  expect(parseLists('{"lists": [null]}').lists).toEqual([]);
  for (const bad of [
    null,
    42,
    "Work",
    [],
    {},
    { id: "L1" },
    { title: "Errands" },
    { id: "", title: "Errands" },
    { id: 7, title: "Errands" },
    { id: "L1", title: 7 },
  ]) {
    expect(parseLists(JSON.stringify({ lists: [bad] })).lists).toEqual([]);
  }
});

test("a sound list survives beside a dropped one", () => {
  const parsed = parseLists(JSON.stringify({ lists: [null, { id: "L2", title: "Work" }] }));
  expect(parsed.lists.length).toBe(1);
  expect(parsed.lists[0].id).toBe("L2");
});

test("default_list is kept when it names a list we kept", () => {
  const parsed = parseLists(
    JSON.stringify({
      lists: [
        { id: "L1", title: "Inbox" },
        { id: "L2", title: "Work" },
      ],
      default_list: "L2",
    }),
  );
  expect(parsed.default_list).toBe("L2");
});

test("a default_list naming nothing on offer is dropped, not carried", () => {
  // The Pane says where a capture is going, and it has no title for a list it
  // was never given — and an unnameable target is one it cannot name.
  for (const answer of [
    { lists: [{ id: "L1", title: "Inbox" }], default_list: "L9" },
    { lists: [{ id: "L1", title: "Inbox" }], default_list: "" },
    { lists: [{ id: "L1", title: "Inbox" }], default_list: 7 },
    { lists: [{ id: "L1", title: "Inbox" }] },
    { lists: [null], default_list: "L1" },
  ]) {
    expect(parseLists(JSON.stringify(answer)).default_list).toBe("");
  }
});

test("a well-formed tasks answer parses to its list id and entries", () => {
  const parsed = parseList(JSON.stringify({ list: "L1", entries: [entry({})] }));
  expect(parsed.list).toBe("L1");
  expect(parsed.entries.length).toBe(1);
});

test("a tasks answer that is not an object is refused rather than guessed at", () => {
  expect(() => parseList("[]")).toThrow();
  expect(() => parseList('{"entries": []}')).toThrow();
  expect(() => parseList('{"list": "L1"}')).toThrow();
});

test("a tasks answer with more entries than the cap is refused whole, not truncated", () => {
  const many = { list: "L1", entries: new Array(MAX_ENTRIES + 1).fill(entry({})) };
  expect(() => parseList(JSON.stringify(many))).toThrow();
  const atCap = { list: "L1", entries: new Array(MAX_ENTRIES).fill(entry({})) };
  expect(parseList(JSON.stringify(atCap)).entries.length).toBe(MAX_ENTRIES);
});

test("a tasks entry that is not an object is refused rather than counted", () => {
  for (const bad of [null, 42, "x", []]) {
    expect(() => parseList(JSON.stringify({ list: "L1", entries: [bad] }))).toThrow();
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

test("parseDue takes the ISO date out of a due answer", () => {
  expect(parseDue('{"input":"+3d","due":"2026-07-23"}')).toBe("2026-07-23");
});

test("parseDue refuses anything apply set_due could not hold", () => {
  // `apply` takes ISO and only ISO. A refusal we can report beats a write that
  // fails at Google.
  for (const bad of [
    "",
    "not json",
    "[]",
    "null",
    '{"input":"milk"}',
    '{"due":null}',
    '{"due":7}',
    '{"due":"tomorrow"}',
    '{"due":"2026-7-23"}',
    '{"due":"26-07-23"}',
    '{"due":"2026-07-23T00:00:00Z"}',
  ]) {
    expect(parseDue(bad)).toBe(null);
  }
});
