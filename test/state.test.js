import { test, expect } from "bun:test";
import {
  OK,
  AUTH_NEEDED,
  STALE,
  stateForExit,
  nextDelaySeconds,
  errorKindOf,
} from "../src/state.js";

test("a clean exit is a good answer", () => {
  expect(stateForExit(0)).toBe(OK);
});

test("exit 3 is the authorization states, and only those", () => {
  expect(stateForExit(3)).toBe(AUTH_NEEDED);
  expect(stateForExit(4)).toBe(STALE);
});

test("every other failure keeps the snapshot rather than nagging", () => {
  [1, 2, 4, 5, 6, 7].forEach((code) => expect(stateForExit(code)).toBe(STALE));
});

test("a good answer schedules the ordinary interval", () => {
  expect(nextDelaySeconds(0, 300, 0)).toBe(300);
});

test("a network failure backs off exponentially", () => {
  expect(nextDelaySeconds(4, 300, 0)).toBe(300);
  expect(nextDelaySeconds(4, 300, 1)).toBe(600);
  expect(nextDelaySeconds(4, 300, 2)).toBe(1200);
});

test("backoff stops at half an hour", () => {
  expect(nextDelaySeconds(4, 300, 9)).toBe(1800);
});

test("backoff never retries sooner than a success would", () => {
  // A 3600s interval capped at 1800 would poll twice as often on failure as on
  // success — the ceiling has to yield to an interval above it.
  expect(nextDelaySeconds(4, 3600, 0)).toBeGreaterThanOrEqual(3600);
  expect(nextDelaySeconds(4, 3600, 3)).toBeGreaterThanOrEqual(3600);
  expect(nextDelaySeconds(4, 1200, 0)).toBe(1200);
  expect(nextDelaySeconds(4, 1200, 3)).toBe(1800);
});

test("an exhausted quota waits an hour, nothing smaller can change it", () => {
  expect(nextDelaySeconds(5, 300, 0)).toBe(3600);
});

test("a missing grant does not back off — no request was made to fail", () => {
  expect(nextDelaySeconds(3, 300, 5)).toBe(300);
});

test("the error kind is lifted from the envelope for the log", () => {
  expect(errorKindOf('{"error":{"kind":"auth_expired","message":"…"}}')).toBe("auth_expired");
});

test("an envelope that is not one yields no kind rather than throwing", () => {
  expect(errorKindOf("segmentation fault")).toBe("");
  expect(errorKindOf("")).toBe("");
  expect(errorKindOf("{}")).toBe("");
});

test("a zero, negative or non-numeric interval is clamped to the floor, not a spawn loop", () => {
  [0, -1, "abc"].forEach((interval) => {
    var delay = nextDelaySeconds(0, interval, 0);
    expect(delay).toBeGreaterThanOrEqual(60);
    expect(delay).toBeLessThanOrEqual(3600);
  });
});

test("an interval below the manifest floor or above its ceiling is clamped", () => {
  expect(nextDelaySeconds(0, 10, 0)).toBe(60);
  expect(nextDelaySeconds(0, 99999, 0)).toBe(3600);
});

test("negative failures never back off below the interval itself", () => {
  var delay = nextDelaySeconds(4, 300, -5);
  expect(delay).toBeGreaterThanOrEqual(300);
  expect(delay).toBeLessThanOrEqual(3600);
});
