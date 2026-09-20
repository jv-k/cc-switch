#!/usr/bin/env bash
# Exercises cc-switch against a throwaway HOME using the file backend.
# The keychain path cannot be tested off macOS and is covered by `cc doctor`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
yes_() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
no_()  { if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

setup() {
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export CC_HOME="$SANDBOX/.config/cc-switch"
    export CC_CLAUDE_HOME="$SANDBOX/.claude"
    export CC_CLAUDE_JSON="$SANDBOX/.claude.json"
    export CC_BACKEND=file
    export CC_NO_ALIASES=1
    export CC_PGREP_PATTERNS='__cc_no_such_process__'
    mkdir -p "$CC_CLAUDE_HOME"
    # shellcheck source=/dev/null
    . "$ROOT/cc-switch.sh"
}

teardown() { rm -rf "$SANDBOX"; }

login_as() {  # login_as <email> <token>
    printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r-%s"}}' "$2" "$2" \
        > "$CC_CLAUDE_HOME/.credentials.json"
    printf '{"oauthAccount":{"emailAddress":"%s"},"projects":{"/tmp/x":{"history":["keep me"]}}}' "$1" \
        > "$CC_CLAUDE_JSON"
}

live_token() { jq -r '.claudeAiOauth.accessToken' "$CC_CLAUDE_HOME/.credentials.json" 2>/dev/null; }

echo "cc-switch tests"

# ---- capture and switch round trip -----------------------------------------
setup
echo "capture / use"
login_as alice@example.com tok-A
cc add main   >/dev/null
cc capture main >/dev/null
is "captures live email"      "$(_cc_profile_email main)" "alice@example.com"
is "marks profile live"       "$(_cc_which)"              "main"

login_as bob@example.com tok-B
cc add backup >/dev/null
cc capture backup >/dev/null
is "second profile captured"  "$(_cc_profile_email backup)" "bob@example.com"

cc use main >/dev/null
is "switch restores token"    "$(live_token)"             "tok-A"
is "switch rewrites identity" "$(_cc_live_email)"         "alice@example.com"
is "live marker follows"      "$(_cc_which)"              "main"
is "unrelated json preserved" "$(jq -r '.projects["/tmp/x"].history[0]' "$CC_CLAUDE_JSON")" "keep me"

cc use backup >/dev/null
is "switch back"              "$(live_token)"             "tok-B"
teardown

# ---- background refresh is saved on the way out ----------------------------
setup
echo "refresh capture on switch"
login_as alice@example.com tok-A
cc add main >/dev/null && cc capture main >/dev/null
login_as bob@example.com tok-B
cc add backup >/dev/null && cc capture backup >/dev/null
cc use main >/dev/null
# simulate a background token refresh while main is live
printf '{"claudeAiOauth":{"accessToken":"tok-A2","refreshToken":"r-tok-A2"}}' \
    > "$CC_CLAUDE_HOME/.credentials.json"
cc use backup >/dev/null
is "refreshed token stored"   "$(jq -r '.claudeAiOauth.accessToken' "$CC_HOME/profiles/main/credentials.json")" "tok-A2"
cc use main >/dev/null
is "refreshed token applied"  "$(live_token)"             "tok-A2"
teardown

# ---- drift detection --------------------------------------------------------
setup
echo "drift detection"
login_as alice@example.com tok-A
cc add main >/dev/null && cc capture main >/dev/null
login_as bob@example.com tok-B
cc add backup >/dev/null && cc capture backup >/dev/null
cc use main >/dev/null
# a manual /login to a third account, behind cc-switch's back
login_as carol@example.com tok-C
cc use backup 2>"$SANDBOX/err" >/dev/null
yes_ "warns on drift"         "grep -q 'does not match' '$SANDBOX/err'"
is   "does not clobber main"  "$(jq -r '.claudeAiOauth.accessToken' "$CC_HOME/profiles/main/credentials.json")" "tok-A"
teardown

# ---- guards -----------------------------------------------------------------
setup
echo "guards"
login_as alice@example.com tok-A
cc add main >/dev/null && cc capture main >/dev/null
no_  "rejects unknown profile"   "cc use nope"
no_  "rejects path traversal"    "cc add ../evil"
no_  "rejects empty profile use" "cc add empty >/dev/null && cc use empty"
is   "empty profile is inert"    "$(live_token)" "tok-A"

# two patterns, so the whitespace split is exercised and not just the first entry
export CC_PGREP_PATTERNS='__cc_absent__ cc_[t]est_marker'
bash -c 'exec -a cc_test_marker sleep 41' & SLEEPER=$!
sleep 0.3
no_  "refuses while claude runs" "cc use main"
yes_ "matches non-first pattern" "_cc_claude_running"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
# no negative assertion here: a wrapping shell's own argv can contain the marker
# string, so pgrep -f matches the harness rather than the target
export CC_PGREP_PATTERNS='__cc_no_such_process__'

mkdir -p "$CC_HOME/.lock"
no_  "honours the lock"          "CC_LOCK_TIMEOUT=0 cc use main"
rmdir "$CC_HOME/.lock"
teardown

# ---- credential file safety -------------------------------------------------
setup
echo "safety"
login_as alice@example.com tok-A
cc add main >/dev/null && cc capture main >/dev/null
is "profile cred is 0600"  "$(stat -c '%a' "$CC_HOME/profiles/main/credentials.json" 2>/dev/null \
                              || stat -f '%Lp' "$CC_HOME/profiles/main/credentials.json")" "600"
no_ "refuses empty write"  "printf '' | _cc_write_live_cred"
cc rm main >/dev/null
no_ "rm deletes profile"   "[ -d '$CC_HOME/profiles/main' ]"
yes_ "rm keeps live cred"  "[ -s '$CC_CLAUDE_HOME/.credentials.json' ]"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
