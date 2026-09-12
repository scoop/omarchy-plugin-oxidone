import { test, expect } from "bun:test";
import { parseVersion, satisfies, MINIMUM } from "../src/version.js";

test("the version line oxidone prints parses to its parts", () => {
  expect(parseVersion("oxidone 1.1.0\n")).toEqual([1, 1, 0]);
});

test("anything that is not that line is refused rather than assumed current", () => {
  expect(parseVersion("")).toBe(null);
  expect(parseVersion("oxidone")).toBe(null);
  expect(parseVersion("some other tool 1.1.0")).toBe(null);
  expect(parseVersion("oxidone v1.1")).toBe(null);
});

test("the floor is 1.2.0, the release that narrowed Today to today's completions", () => {
  expect(MINIMUM).toEqual([1, 2, 0]);
});

test("a version at or above the floor satisfies it", () => {
  expect(satisfies([1, 2, 0], MINIMUM)).toBe(true);
  expect(satisfies([1, 3, 0], MINIMUM)).toBe(true);
  expect(satisfies([2, 0, 0], MINIMUM)).toBe(true);
});

test("1.1.0 does not satisfy it — its `json today` is status-blind", () => {
  expect(satisfies([1, 1, 0], MINIMUM)).toBe(false);
  expect(satisfies([1, 0, 0], MINIMUM)).toBe(false);
  expect(satisfies([1, 1, 99], MINIMUM)).toBe(false);
});

test("an unparseable version satisfies nothing", () => {
  expect(satisfies(null, MINIMUM)).toBe(false);
});
