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
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no '$3' in: $2" ;; esac; }

setup() {
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX"
    export CC_HOME="$SANDBOX/.config/cc-switch"
    export CC_CLAUDE_HOME="$SANDBOX/.claude"
    export CC_CLAUDE_JSON="$SANDBOX/.claude.json"
    export CC_BACKEND=file
    unset CC_SHARED CC_CLAUDE_BIN CC_LAUNCH_LOG
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

# ---- rotation over 4 subs ---------------------------------------------------
setup
echo "rotation"
for n in a b c d; do
    login_as "$n@example.com" "tok-$n"
    cc add "$n" >/dev/null && cc capture "$n" >/dev/null
done
cc use a >/dev/null
is "ring advances"            "$(_cc_next_available)"   "b"
cc next >/dev/null
is "next switches"            "$(_cc_which)"            "b"
is "next applied token"       "$(live_token)"           "tok-b"

cc spent b >/dev/null
is "skips spent"              "$(_cc_next_available)"   "c"
has  "ls reports spent"       "$(cc ls)" "spent, back in"

cc use d >/dev/null
is "wraps past the end"       "$(_cc_next_available)"   "a"

cc spent a >/dev/null; cc spent c >/dev/null; cc spent d >/dev/null
is "none left"                "$(_cc_next_available)"   ""
no_  "next fails when spent"  "cc next"
has  "reports soonest reset"  "$(cc next 2>&1)" "earliest is"

cc clear --all >/dev/null
is "clear --all restores"     "$(_cc_next_available)"   "a"
teardown

# ---- spent markers expire on their own --------------------------------------
setup
echo "quota expiry"
login_as a@example.com tok-a; cc add a >/dev/null && cc capture a >/dev/null
login_as b@example.com tok-b; cc add b >/dev/null && cc capture b >/dev/null
cc use a >/dev/null
cc spent a 1s >/dev/null
yes_ "marked spent"           "_cc_is_limited a"
sleep 1.2
no_  "expires without help"   "_cc_is_limited a"
no_  "marker file removed"    "[ -e '$CC_HOME/profiles/a/spent' ]"
no_  "rejects bad duration"   "cc spent b 5x"
is   "parses hours"           "$(_cc_parse_dur 5h)"     "18000"
is   "parses minutes"         "$(_cc_parse_dur 90m)"    "5400"
is   "formats remaining"      "$(_cc_human 14820)"      "4h07m"
teardown

# ---- go / flip --------------------------------------------------------------
setup
echo "go and flip"
export CC_CLAUDE_BIN="$SANDBOX/fake-claude"
cat > "$CC_CLAUDE_BIN" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_LAUNCH_LOG"
FAKE
chmod +x "$CC_CLAUDE_BIN"
export CC_LAUNCH_LOG="$SANDBOX/launches"
: > "$CC_LAUNCH_LOG"

login_as a@example.com tok-a; cc add a >/dev/null && cc capture a >/dev/null
login_as b@example.com tok-b; cc add b >/dev/null && cc capture b >/dev/null
cc use a >/dev/null

cc go >/dev/null
is "go stays put when ready"  "$(_cc_which)"            "a"
is "go resumes"               "$(tail -n1 "$CC_LAUNCH_LOG")" "--continue"

cc flip >/dev/null
is "flip rotates"             "$(_cc_which)"            "b"
yes_ "flip marks old spent"   "_cc_is_limited a"
is   "flip resumes"           "$(tail -n1 "$CC_LAUNCH_LOG")" "--continue"

cc go --model opus >/dev/null
is "go passes args through"   "$(tail -n1 "$CC_LAUNCH_LOG")" "--continue --model opus"

cc clear a >/dev/null
cc spent b >/dev/null
cc go >/dev/null 2>&1
is "go rotates when spent"    "$(_cc_which)"            "a"
is "go resumed after rotate"  "$(tail -n1 "$CC_LAUNCH_LOG")" "--continue"
teardown

# ---- linked env -------------------------------------------------------------
setup
echo "linked env"
login_as a@example.com tok-a; cc add a >/dev/null && cc capture a >/dev/null
mkdir -p "$CC_CLAUDE_HOME/projects" "$CC_CLAUDE_HOME/todos"
echo hi > "$CC_CLAUDE_HOME/history.jsonl"
echo md > "$CC_CLAUDE_HOME/CLAUDE.md"
cc link a >/dev/null
yes_ "links transcripts"      "[ -L '$CC_HOME/envs/a/projects' ]"
yes_ "links history"          "[ -L '$CC_HOME/envs/a/history.jsonl' ]"
yes_ "link resolves"          "[ \"\$(cat '$CC_HOME/envs/a/history.jsonl')\" = hi ]"
no_  "skips absent paths"     "[ -e '$CC_HOME/envs/a/agents' ]"
is   "env prints export"      "$(cc env a)" "export CLAUDE_CONFIG_DIR=$CC_HOME/envs/a"
no_  "env fails if unlinked"  "cc env nope"
cc link a >/dev/null
yes_ "link is idempotent"     "[ -L '$CC_HOME/envs/a/projects' ]"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
