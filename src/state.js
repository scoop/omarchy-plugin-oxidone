// oxidone's exit codes turned into the states the bar can be in.
//
// The CLI's codes are documented in oxidone's docs/json-cli.md: 1 internal,
// 2 usage, 3 not_configured/auth_expired/token_store_failed, 4 network/
// rate_limited/pagination, 5 rejected/quota_exhausted, 6 not_found, 7 refused.
//
// The bar has far fewer states than that, deliberately. Five of those codes are
// indistinguishable to someone standing at a bar widget, and inventing a state
// per code would be a lot of QML for states nobody can act on.

/** A fresh answer arrived. */
var OK = "ok";
/** oxidone has no usable grant. Only the TUI can fix it. */
var AUTH_NEEDED = "auth-needed";
/** The last answer stands because a newer one could not be had. */
var STALE = "stale";
/** No usable oxidone at the configured path. */
var UNUSABLE = "unusable";

function stateForExit(code) {
  if (code === 0) {
    return OK;
  }
  // Exit 3 is the whole authorization family — no credentials configured, a
  // dead grant, or a token file that cannot be read. All three mean the same
  // thing to us: run the TUI.
  if (code === 3) {
    return AUTH_NEEDED;
  }
  // Everything else keeps the Snapshot. 1 and 2 are our own fault and get
  // logged; 5, 6 and 7 only reach a write, which slice 1 does not make.
  return STALE;
}

function nextDelaySeconds(code, intervalSeconds, failures) {
  // The manifest's min/max are a settings-UI hint; the shell validates nothing,
  // so whatever sits in shell.json arrives here raw. An interval of 0 would make
  // this a process-spawn loop inside the user's desktop shell, so the floor is
  // enforced where every caller passes rather than at the edges where it can be
  // forgotten.
  var interval = Math.min(3600, Math.max(60, Number(intervalSeconds) || 300));
  var attempts = Math.max(0, Math.floor(Number(failures) || 0));
  if (code === 0) {
    return interval;
  }
  // An exhausted daily quota cannot change inside a poll interval, and retrying
  // into it just spends the next day's allowance early.
  if (code === 5) {
    return 3600;
  }
  // Nothing was sent, so there is nothing to be gentle with — and a grant can
  // come back the moment the TUI is run.
  if (code === 3) {
    return interval;
  }
  var doublings = Math.min(attempts, 3);
  return Math.min(interval * Math.pow(2, doublings), 1800);
}

// oxidone prints {"error":{"kind","message"}} on stderr. The kind is worth
// logging; the message is oxidone's to phrase and ours to stay out of.
function errorKindOf(stderr) {
  try {
    var body = JSON.parse(String(stderr || ""));
    if (body && body.error && typeof body.error.kind === "string") {
      return body.error.kind;
    }
  } catch (ignored) {
    // Not an envelope. A crash, a wrapper's noise, or nothing at all.
  }
  return "";
}

if (typeof module !== "undefined") {
  module.exports = {
    OK: OK,
    AUTH_NEEDED: AUTH_NEEDED,
    STALE: STALE,
    UNUSABLE: UNUSABLE,
    stateForExit: stateForExit,
    nextDelaySeconds: nextDelaySeconds,
    errorKindOf: errorKindOf,
  };
}
