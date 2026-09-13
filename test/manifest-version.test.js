import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";

// Read rather than import: tsconfig.json leaves resolveJsonModule off, so
// `import manifest from "../manifest.json"` would fail `bun run typecheck`.
function read(name) {
  return JSON.parse(readFileSync(new URL(`../${name}`, import.meta.url), "utf8"));
}

// release-please bumps package.json through its node strategy and manifest.json
// through a separate `extra-files` updater. That updater fails *quietly* — a bad
// jsonpath logs "No version found. Skipping." as a warning and still opens a
// normal-looking release PR, leaving manifest.json behind. manifest.json is the
// version the Omarchy plugin directory reads and the only one users ever see, so
// the drift has to fail the gate rather than ship.
test("manifest.json and package.json carry the same version", () => {
  expect(read("manifest.json").version).toBe(read("package.json").version);
});
