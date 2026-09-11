// The version gate. `oxidone json` first shipped in 1.1.0; 1.0.0 prints a
// version perfectly happily and has no such subcommand, so "it runs and prints"
// is not evidence the contract is there.

/** The floor: the release the json entry point shipped in. */
var MINIMUM = [1, 1, 0];

// `oxidone --version` prints exactly `oxidone X.Y.Z`. Anything else — another
// tool on the configured path, a wrapper script, an error — is not a version.
function parseVersion(stdout) {
  var found = /^oxidone (\d+)\.(\d+)\.(\d+)\s*$/m.exec(String(stdout || ""));
  if (!found) {
    return null;
  }
  return [Number(found[1]), Number(found[2]), Number(found[3])];
}

function satisfies(version, floor) {
  if (!version) {
    return false;
  }
  for (var i = 0; i < 3; i++) {
    if (version[i] > floor[i]) {
      return true;
    }
    if (version[i] < floor[i]) {
      return false;
    }
  }
  return true;
}

if (typeof module !== "undefined") {
  module.exports = { MINIMUM: MINIMUM, parseVersion: parseVersion, satisfies: satisfies };
}
