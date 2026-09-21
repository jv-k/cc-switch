#!/usr/bin/env bash
# Exercises cc-switch against a throwaway HOME using the file backend.
# The keychain path cannot be tested off macOS and is covered by `cc doctor`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"          # captured before any setup() reassigns it
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
yes_() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
no_()  { if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no '$3' in: $2" ;; esac; }
ESC="$(printf '\033')"
strip() { sed "s/$ESC\[[0-9;]*m//g"; }

# 2026-09-21: a mis-quoted one-liner (`export HOME=$(mktemp -d) CC_HOME=$HOME/...`
# expands $HOME to the OLD value) pointed CC_* at the real dotfiles and truncated
# a live ~/.claude.json. Nothing here may address anything outside the sandbox.
sandboxed() {
    local var val
    for var in CC_HOME CC_CLAUDE_HOME CC_CLAUDE_JSON; do
        eval "val=\${$var:-}"
        case "$val" in
            "$SANDBOX"/*) ;;
            *) printf 'REFUSING TO RUN: %s=%s is outside the sandbox %s\n' "$var" "$val" "$SANDBOX" >&2
               return 1 ;;
        esac
    done
    return 0
}

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
    unset NO_COLOR CLICOLOR_FORCE FORCE_COLOR
    sandboxed || exit 1
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
is  "capture reports"         "$(cc capture)"             "✔ Captured backup (bob@example.com)"
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
rm -f "$CC_HOME/live"
has  "bare capture needs live"   "$(cc capture 2>&1)" "Usage: cc capture"
printf 'main' > "$CC_HOME/live"
no_  "rejects empty profile use" "cc add empty >/dev/null && cc use empty"
is   "empty profile is inert"    "$(live_token)" "tok-A"

# two patterns, so the whitespace split is exercised and not just the first entry
export CC_PGREP_PATTERNS='__cc_absent__ cc_[t]est_marker'
bash -c 'exec -a cc_test_marker sleep 41' & SLEEPER=$!
sleep 0.3
no_  "refuses while claude runs" "cc use main"
yes_ "matches non-first pattern" "_cc_claude_running"
has  "refusal lists processes"   "$(cc use main 2>&1)" "↳ 1 × cc_test_marker"
has  "doctor counts processes"   "$(cc doctor)"        "claude running : yes (1)"
has  "doctor lists processes"    "$(cc doctor)"        "↳ 1 × cc_test_marker"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null

# the shipped patterns must see a native install and the VS Code extension,
# whose binaries are `claude` and .../native-binary/claude respectively
# shellcheck disable=SC2016  # the inner script expands in the child bash
defaults="$(env -u CC_PGREP_PATTERNS bash -c '. "$1"; printf "%s" "$CC_PGREP_PATTERNS"' _ "$ROOT/cc-switch.sh")"
matches() { _cc_words "$defaults" | while IFS= read -r p; do printf '%s\n' "$1" | grep -Eq -- "$p" && echo hit; done; }
has  "default sees bare claude"  "$(matches 'claude')"                       "hit"
has  "default sees claude+args"  "$(matches 'claude --resume')"              "hit"
is   "default skips claude-foo"  "$(matches 'claude-usage')"                 ""
has  "default sees vscode"       "$(matches '/x/native-binary/claude --output-format stream-json')" "hit"
mkdir -p "$SANDBOX/native-binary"
bash -c "exec -a '$SANDBOX/native-binary/claude' sleep 41" & SLEEPER=$!
sleep 0.3
has  "lists vscode with ~"       "$(CC_PGREP_PATTERNS="$defaults" _cc_claude_procs)" "1 ~/native-binary/claude"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
# no negative assertion here: a wrapping shell's own argv can contain the marker
# string, so pgrep -f matches the harness rather than the target
export CC_PGREP_PATTERNS='__cc_no_such_process__'

mkdir -p "$CC_HOME/.lock"
no_  "honours the lock"          "CC_LOCK_TIMEOUT=0 cc use main"
rmdir "$CC_HOME/.lock"

# the harness guard itself
yes_ "sandbox guard passes"      "sandboxed"
no_  "guard catches real paths"  "CC_CLAUDE_JSON=$REAL_HOME/.claude.json sandboxed"
no_  "guard catches real home"   "CC_HOME=$REAL_HOME/.config/cc-switch sandboxed"

# forcing the file backend on a Keychain machine writes a file Claude Code
# never reads: the switch looks like it worked and changes nothing
# shellcheck disable=SC2329,SC2317  # stubs, called indirectly by cc doctor
_cc_keychain_available() { return 0; }
has "doctor flags dead backend"  "$(cc doctor 2>&1)" "file backend is forced but this machine stores the credential in the Keychain"
# shellcheck disable=SC2329,SC2317
_cc_keychain_available() { return 1; }
no_ "no flag without keychain"   "cc doctor 2>&1 | grep -q 'Keychain'"
unset -f _cc_keychain_available
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
has  "reports soonest reset"  "$(cc next 2>&1)" "Earliest is"

cc clear --all >/dev/null
is "clear --all restores"     "$(_cc_next_available)"   "a"

is  "status aliases ls"       "$(cc status)"            "$(cc ls)"
is  "current aliases which"   "$(cc current)"           "d"
has "usage lists aliases"     "$(cc --help)"            "status=ls"
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
printf 'garbage' > "$CC_HOME/profiles/a/spent"
no_  "malformed marker ignored" "_cc_is_limited a"
no_  "malformed marker reaped"  "[ -e '$CC_HOME/profiles/a/spent' ]"
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

# ---- the identity file follows CLAUDE_CONFIG_DIR ----------------------------
# With CLAUDE_CONFIG_DIR set, Claude Code keeps .claude.json inside it; with it
# unset, at $HOME/.claude.json. cc must read the same file Claude Code writes,
# or a linked env captures the serial account instead of its own.
setup
echo "identity file location"
unset CC_CLAUDE_JSON
env_dir="$SANDBOX/envs/work"; mkdir -p "$env_dir"
is "defaults to \$HOME"        "$(CLAUDE_CONFIG_DIR='' _cc_claude_json)"           "$SANDBOX/.claude.json"
is "follows the config dir"    "$(CLAUDE_CONFIG_DIR=$env_dir _cc_claude_json)"   "$env_dir/.claude.json"
is "explicit setting wins"     "$(CC_CLAUDE_JSON=$SANDBOX/x.json CLAUDE_CONFIG_DIR=$env_dir _cc_claude_json)" "$SANDBOX/x.json"

# a capture inside a linked env must snapshot that env's account, not the serial one
export CC_CLAUDE_JSON="$SANDBOX/.claude.json"
login_as serial@example.com tok-serial
cc add outer >/dev/null && cc capture outer >/dev/null
unset CC_CLAUDE_JSON
printf '{"oauthAccount":{"emailAddress":"linked@example.com"}}' > "$env_dir/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"tok-linked"}}' > "$CC_CLAUDE_HOME/.credentials.json"
CLAUDE_CONFIG_DIR="$env_dir" cc add inner >/dev/null
CLAUDE_CONFIG_DIR="$env_dir" cc capture inner >/dev/null
is "captures the env account"  "$(_cc_profile_email inner)"  "linked@example.com"
is "serial capture unaffected" "$(_cc_profile_email outer)"  "serial@example.com"
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

# ---- output style -----------------------------------------------------------
setup
echo "output style"
login_as a@example.com tok-a; cc add a >/dev/null && cc capture a >/dev/null
login_as b@example.com tok-b; cc add b >/dev/null && cc capture b >/dev/null
is   "plain when piped"          "$(cc ls | grep -c "$ESC")" "0"
has  "CLICOLOR_FORCE=1 forces"   "$(CLICOLOR_FORCE=1 cc ls)" "$ESC"
has  "FORCE_COLOR=1 forces"      "$(FORCE_COLOR=1 cc ls)"    "$ESC"
no_  "FORCE_COLOR=0 is off"      "FORCE_COLOR=0 _cc_want_color 1"
no_  "NO_COLOR beats force"      "NO_COLOR=1 CLICOLOR_FORCE=1 _cc_want_color 1"
is   "colour adds no text: ls"   "$(CLICOLOR_FORCE=1 cc ls | strip)"     "$(cc ls)"
is   "colour adds no text: help" "$(CLICOLOR_FORCE=1 cc --help | strip)" "$(cc --help)"
is   "colour adds no text: doctor" "$(CLICOLOR_FORCE=1 cc doctor | strip)" "$(cc doctor)"
is   "which stays raw"           "$(CLICOLOR_FORCE=1 cc which)"          "b"
cc link b >/dev/null
is   "env stays raw"             "$(CLICOLOR_FORCE=1 cc env b)"          "export CLAUDE_CONFIG_DIR=$CC_HOME/envs/b"

has  "ls has a header"           "$(cc ls)" "PROFILE"
has  "ls marks live"             "$(cc ls)" "→ b "
has  "ls leaves idle unmarked"   "$(cc ls)" "  a "
cc add c >/dev/null
has  "ls names the capture cmd"  "$(cc ls)" "run: cc capture c"
has  "help has section pills"    "$(cc --help)" " PROFILES "
has  "help names the live glyph" "$(cc --help)" "→ marks live"

is   "switch reports old -> new" "$(cc use a)"            "✔ Switched b → a (a@example.com)"
is   "no-op switch is info"      "$(cc use a)"            "ℹ Already on a (a@example.com)"
rm -f "$CC_HOME/live"
is   "first switch says to"      "$(cc use b)"            "✔ Switched to b (b@example.com)"
is   "spent reports"             "$(cc spent a 90m)"      "✔ Marked a spent, back in 1h30m"
is   "clear reports"             "$(cc clear a)"          "✔ Cleared a, available again"
is   "clear --all reports"       "$(cc clear --all)"      "✔ Cleared all spent markers"
is   "add reports"               "$(cc add d | head -n1)" "✔ Created d"
has  "add hints capture"         "$(cc add d)"            "↳ cc capture d"
is   "rm reports"                "$(cc rm d | head -n1)"  "✔ Removed d"
is   "link reports"              "$(cc link a | head -n1)" "✔ Linked env at $CC_HOME/envs/a"
has  "link hints eval"           "$(cc link a)"           "↳ eval \"\$(cc env a)\""
is   "error prefix"              "$(cc use nope 2>&1)"    "✖ Unknown profile 'nope'"
mkdir -p "$CC_HOME/.lock" && touch -t 202001010000 "$CC_HOME/.lock"
is   "warning prefix"            "$(cc use a 2>&1 >/dev/null | head -n1)" "! Clearing stale lock"
cc spent a >/dev/null; cc spent b >/dev/null; cc rm c >/dev/null
has  "soonest is info"           "$(cc next 2>&1)"        "ℹ Earliest is"
teardown

# ---- prompt snippets see quota state --------------------------------------
setup
echo "prompt state"
login_as a@example.com tok-a; cc add a >/dev/null && cc capture a >/dev/null
json="{\"workspace\":{\"current_dir\":\"$SANDBOX\"},\"model\":{\"display_name\":\"Opus\"}}"
statusline() { printf '%s' "$json" | bash "$ROOT/prompt/statusline.sh"; }
has  "statusline shows profile"  "$(statusline | strip)" "| a |"
has  "statusline ready is green" "$(statusline)" "$(printf '\033[32ma\033[0m')"
cc spent a 90m >/dev/null
has  "statusline flags spent"    "$(statusline | strip)" "| a spent 1h"
has  "statusline spent is yellow" "$(statusline)" "$(printf '\033[33ma spent')"
cc clear a >/dev/null

whens="$(sed -n "s/^when = '\(.*\)'$/\1/p" "$ROOT/prompt/starship.toml")"
ready_when="$(printf '%s\n' "$whens" | sed -n 1p)"
spent_when="$(printf '%s\n' "$whens" | sed -n 2p)"
yes_ "starship ready module shows" "bash --noprofile --norc -c '$ready_when'"
no_  "starship spent module hides" "bash --noprofile --norc -c '$spent_when'"
cc spent a 90m >/dev/null
no_  "starship ready module hides" "bash --noprofile --norc -c '$ready_when'"
yes_ "starship spent module shows" "bash --noprofile --norc -c '$spent_when'"
cc clear a >/dev/null

if command -v zsh >/dev/null 2>&1; then
    zprompt() { zsh -c "source '$ROOT/prompt/zsh.zsh'; _cc_rprompt; print -r -- \"\$RPROMPT\""; }
    zp10k()   { zsh -c "p10k() { print -r -- \"\$@\"; }; source '$ROOT/prompt/p10k.zsh'; prompt_cc_account"; }
    has "zsh prompt ready"       "$(zprompt)" "%F{green}a%f"
    has "p10k ready state"       "$(zp10k)"   "-s READY"
    cc spent a 90m >/dev/null
    has "zsh prompt spent"       "$(zprompt)" "%F{yellow}cc:a spent%f"
    has "p10k spent state"       "$(zp10k)"   "-s SPENT"
fi
teardown

# ---- prompt snippets agree with the library on where the state file is -----
echo "prompt snippets"
# shellcheck disable=SC2016  # literal: it is what the files must contain
default='${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch'
yes_ "library default"        "grep -qF -- 'CC_HOME:=$default}' '$ROOT/cc-switch.sh'"
for f in zsh.zsh p10k.zsh starship.toml statusline.sh; do
    yes_ "$f reads it"        "grep -qF -- 'CC_HOME:-$default}' '$ROOT/prompt/$f'"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
