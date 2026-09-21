# shellcheck shell=bash
#
# cc-switch — swap Claude Code accounts in place, keep one local state tree.
#
# Source from ~/.zshrc or ~/.bashrc:
#     source /path/to/cc-switch.sh
#
# Serial mode deliberately does NOT touch CLAUDE_CONFIG_DIR. One ~/.claude
# means one projects/ tree, one history.jsonl, one MCP config, one CLAUDE.md.
# The only thing that changes between profiles is which OAuth token is live.
# Concurrent mode (cc link / cc env) is the opt-in exception: a per-profile
# CLAUDE_CONFIG_DIR with the shared tree symlinked back in.

# ---------------------------------------------------------------- config ----

: "${CC_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}"
: "${CC_CLAUDE_HOME:=$HOME/.claude}"
: "${CC_CLAUDE_JSON:=$HOME/.claude.json}"
: "${CC_KEYCHAIN_SERVICE:=Claude Code-credentials}"
: "${CC_ACCOUNT_KEYS:=oauthAccount}"   # space-separated top-level keys of ~/.claude.json
: "${CC_LOCK_TIMEOUT:=5}"              # seconds
: "${CC_LIMIT_DEFAULT:=5h}"            # assumed window when you mark a sub spent
: "${CC_CLAUDE_BIN:=claude}"
: "${CC_RESUME_FLAG:=--continue}"      # --continue resumes the last session in $PWD
# CC_SHARED: state tree that linked envs share. Resolved lazily by _cc_shared
# so it tracks CC_CLAUDE_HOME if that is changed after sourcing.
: "${CC_LINK_PATHS:=projects history.jsonl todos CLAUDE.md agents commands skills plugins}"
# Space-separated pgrep -f patterns, no spaces within one. Cover the npm
# install, the old ~/.claude/local wrapper, the native binary (argv is just
# `claude`) and the VS Code extension's bundled copy.
: "${CC_PGREP_PATTERNS:=[c]laude/cli\.js [.]claude/local/claude ^claude([[:space:]]|$) [n]ative-binary/claude}"

# ----------------------------------------------------------------- style ----
#
# Colour gate, decided per stream so `cc use x 2>log` keeps the log clean.
# Precedence:
#   1. NO_COLOR set (any value)            -> off   (https://no-color.org)
#   2. CLICOLOR_FORCE / FORCE_COLOR truthy -> on    (piping into `less -R`, CI)
#   3. the stream is a TTY                 -> on
#   4. otherwise (pipe, file)              -> off
_cc_want_color() {   # $1 = fd
    [ -z "${NO_COLOR:-}" ] || return 1
    { [ -n "${CLICOLOR_FORCE:-}" ] && [ "$CLICOLOR_FORCE" != 0 ]; } && return 0
    { [ -n "${FORCE_COLOR:-}" ] && [ "$FORCE_COLOR" != 0 ]; } && return 0
    [ -t "$1" ]
}

# Symbol vocabulary. Characters only; colour is applied at the call site.
_cc_i_ok='✔' _cc_i_warn='!' _cc_i_err='✖' _cc_i_info='ℹ' _cc_i_arrow='→' _cc_i_trace='↳'

# Semantic styles for stdout, resolved by _cc_style once per cc call. Plain
# until then, so internal functions print clean text when called directly.
_cc_s_ok='' _cc_s_info='' _cc_s_attn='' _cc_s_err='' _cc_s_val='' _cc_s_dim='' _cc_s_norm=''
_cc_s_hdr='' _cc_s_brand='' _cc_s_end=''

_cc_style() {
    if _cc_want_color 1; then
        _cc_s_ok=$'\033[0;32m'    # ✔ lines
        _cc_s_info=$'\033[0;36m'  # ℹ lines
        _cc_s_attn=$'\033[1;33m'  # spent, running
        _cc_s_err=$'\033[0;31m'   # absent, missing
        _cc_s_val=$'\033[0;32m'   # inline values: profile names, paths
        _cc_s_dim=$'\033[2m'      # secondary: emails, hints, headers
        _cc_s_norm=$'\033[1m'     # emphasis: the live profile, command names
        # inverted-video pills for headers: one combined sequence, because a
        # standalone fg code starts with a reset that would cancel the invert
        _cc_s_hdr=$'\033[7;1;36m'     # cyan, section headers
        _cc_s_brand=$'\033[7;1;32m'   # green, the name at the top of --help
        _cc_s_end=$'\033[0m'
    else
        _cc_s_ok='' _cc_s_info='' _cc_s_attn='' _cc_s_err='' _cc_s_val='' _cc_s_dim='' _cc_s_norm=''
        _cc_s_hdr='' _cc_s_brand='' _cc_s_end=''
    fi
}

# ----------------------------------------------------------------- utils ----

# Status lines: icon + body. Bodies may carry inline styles from the caller.
_cc_ok()    { printf '%s%s%s %s\n' "$_cc_s_ok" "$_cc_i_ok" "$_cc_s_end" "$*"; }
_cc_info()  { printf '%s%s%s %s\n' "$_cc_s_info" "$_cc_i_info" "$_cc_s_end" "$*"; }
_cc_trace() { printf '  %s%s %s%s\n' "$_cc_s_dim" "$_cc_i_trace" "$*" "$_cc_s_end"; }
_cc_emit()  {   # fd sgr icon message...  (stderr decides its own colour)
    local fd="$1" tag="$3"
    _cc_want_color "$fd" && tag="$2$3"$'\033[0m'
    shift 3
    printf '%s %s\n' "$tag" "$*" >&"$fd"
}
_cc_err()   { _cc_emit 2 $'\033[0;31m' "$_cc_i_err" "$@"; }
_cc_warn()  { _cc_emit 2 $'\033[1;33m' "$_cc_i_warn" "$@"; }
_cc_val()   { printf '%s%s%s' "$_cc_s_val" "$1" "$_cc_s_end"; }
_cc_who()   { printf '%s %s(%s)%s' "$(_cc_val "$1")" "$_cc_s_dim" "$(_cc_profile_email "$1")" "$_cc_s_end"; }
_cc_section() { printf '\n%s %s %s\n' "$_cc_s_hdr" "$1" "$_cc_s_end"; }   # inverted pill, pass UPPERCASE
_cc_need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    _cc_err "Missing required command: $1"
    return 1
}

# atomic write from stdin, 0600
_cc_write() {
    local dest="$1" tmp
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    chmod 600 "$tmp" 2>/dev/null
    if cat > "$tmp"; then
        mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"
        return 1
    fi
}

_cc_lock() {
    local lock="$CC_HOME/.lock" waited=0
    mkdir -p "$CC_HOME" 2>/dev/null
    # clear a lock left behind by a killed run
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        _cc_warn "Clearing stale lock"
        rmdir "$lock" 2>/dev/null
    fi
    while ! mkdir "$lock" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt $((CC_LOCK_TIMEOUT * 10)) ]; then
            _cc_err "Another cc-switch operation is running ($lock)"
            return 1
        fi
        sleep 0.1
    done
    return 0
}

_cc_unlock() { rmdir "$CC_HOME/.lock" 2>/dev/null || true; }

_cc_valid_name() {
    case "$1" in
        ''|.|..|*/*|*' '*|.*) return 1 ;;
        *) return 0 ;;
    esac
}

_cc_require_profile() {
    [ -d "$CC_HOME/profiles/$1" ] && return 0
    _cc_err "Unknown profile '$1'"
    return 1
}

# one word per line. Explicit, because zsh does not word-split unquoted expansions.
_cc_words() { printf '%s\n' "$1" | tr ' ' '\n'; }

# --------------------------------------------------------------- backend ----

_cc_backend() {
    if [ -n "${CC_BACKEND:-}" ]; then printf '%s' "$CC_BACKEND"; return; fi
    if [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1 \
       && security find-generic-password -s "$CC_KEYCHAIN_SERVICE" >/dev/null 2>&1; then
        printf 'keychain'
    else
        printf 'file'
    fi
}

# Claude Code creates the keychain item with its own account name. Reuse it so
# -U updates in place instead of creating a second item.
_cc_keychain_account() {
    local acct
    acct="$(security find-generic-password -s "$CC_KEYCHAIN_SERVICE" 2>&1 \
            | sed -n 's/^[[:space:]]*"acct"<blob>="\(.*\)"$/\1/p' | head -n1)"
    if [ -n "$acct" ]; then printf '%s' "$acct"; else id -un; fi
}

_cc_read_live_cred() {
    case "$(_cc_backend)" in
        keychain) security find-generic-password -s "$CC_KEYCHAIN_SERVICE" -w 2>/dev/null ;;
        file)     cat "$CC_CLAUDE_HOME/.credentials.json" 2>/dev/null ;;
    esac
}

# Keychain write via `security -i` so the token never appears in argv (and so
# never in `ps`). Falls back to the argv form if the readback does not match.
_cc_keychain_put() {
    local payload="$1" acct escaped
    acct="$(_cc_keychain_account)"
    escaped="$(printf '%s' "$payload" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' \
        "$CC_KEYCHAIN_SERVICE" "$acct" "$escaped" | security -i >/dev/null 2>&1
    if [ "$(_cc_read_live_cred)" = "$payload" ]; then
        return 0
    fi
    _cc_warn "Keychain stdin write failed, falling back to argv (briefly visible to ps)"
    security add-generic-password -U -s "$CC_KEYCHAIN_SERVICE" -a "$acct" -w "$payload" \
        >/dev/null 2>&1 || return 1
    [ "$(_cc_read_live_cred)" = "$payload" ]
}

_cc_write_live_cred() {
    local payload
    payload="$(cat)"
    [ -n "$payload" ] || { _cc_err "Refusing to write an empty credential"; return 1; }
    case "$(_cc_backend)" in
        keychain)
            _cc_keychain_put "$payload"
            ;;
        file)
            mkdir -p "$CC_CLAUDE_HOME" || return 1
            printf '%s' "$payload" | _cc_write "$CC_CLAUDE_HOME/.credentials.json"
            ;;
    esac
}

# -------------------------------------------------------------- identity ----

_cc_email_of() {
    [ -s "$1" ] || return 0
    jq -r '.. | objects | (.emailAddress // .email // empty)' "$1" 2>/dev/null | head -n1
}

_cc_live_email()    { _cc_email_of "$CC_CLAUDE_JSON"; }
_cc_which()         { cat "$CC_HOME/live" 2>/dev/null; }
_cc_profile_email() { _cc_email_of "$CC_HOME/profiles/$1/account.json"; }

# Running Claude Code processes grouped by executable: "<count> <path>" per
# line, $HOME shortened to ~. The path is what tells a VS Code tab from a
# terminal session.
_cc_claude_procs() {
    local pid exe
    command -v pgrep >/dev/null 2>&1 || return 0
    _cc_words "$CC_PGREP_PATTERNS" | while IFS= read -r p; do
        [ -n "$p" ] && pgrep -f "$p" 2>/dev/null
    done | sort -un | while IFS= read -r pid; do
        exe="$(ps -o args= -p "$pid" 2>/dev/null)"; exe="${exe%% *}"
        [ -n "$exe" ] || continue
        case "$exe" in "$HOME"/*) exe="~${exe#"$HOME"}" ;; esac
        printf '%s\n' "$exe"
    done | sort | uniq -c | sed 's/^ *//'
}

_cc_claude_running() { [ -n "$(_cc_claude_procs)" ]; }

# ------------------------------------------------------ capture and apply ----

_cc_capture() {
    local name="${1:-$(_cc_which)}" dir cred
    [ -n "$name" ] || { _cc_err "Usage: cc capture <profile> (no live profile to default to)"; return 1; }
    _cc_valid_name "$name" || { _cc_err "Bad profile name: '$name'"; return 1; }
    dir="$CC_HOME/profiles/$name"
    mkdir -p "$dir" || return 1

    cred="$(_cc_read_live_cred)"
    [ -n "$cred" ] || { _cc_err "No live credential found (backend: $(_cc_backend))"; return 1; }
    printf '%s' "$cred" | _cc_write "$dir/credentials.json" || return 1

    if [ -s "$CC_CLAUDE_JSON" ]; then
        jq --arg keys "$CC_ACCOUNT_KEYS" \
           '($keys | split(" ")) as $k | with_entries(select(.key as $x | $k | index($x)))' \
           "$CC_CLAUDE_JSON" 2>/dev/null | _cc_write "$dir/account.json" \
            || _cc_warn "Could not snapshot account keys from $CC_CLAUDE_JSON"
    fi

    printf '%s' "$name" > "$CC_HOME/live"
    _cc_ok "Captured $(_cc_who "$name")"
}

_cc_apply() {
    local name="$1" dir="$CC_HOME/profiles/$1"
    [ -s "$dir/credentials.json" ] || {
        _cc_err "Profile '$name' holds no credential. Run: cc capture $name"
        return 1
    }
    _cc_write_live_cred < "$dir/credentials.json" || return 1

    if [ -s "$dir/account.json" ] && [ -s "$CC_CLAUDE_JSON" ]; then
        jq -s '.[0] * .[1]' "$CC_CLAUDE_JSON" "$dir/account.json" 2>/dev/null \
            | _cc_write "$CC_CLAUDE_JSON" \
            || { _cc_err "Failed to merge account metadata into $CC_CLAUDE_JSON"; return 1; }
    fi

    printf '%s' "$name" > "$CC_HOME/live"
    return 0
}

# -------------------------------------------------------------- commands ----

_cc_use() {
    local target="$1" live rc=0 snap_cred snap_json procs
    _cc_valid_name "$target" || { _cc_err "Usage: cc use <profile>"; return 1; }
    _cc_require_profile "$target" || return 1

    procs="$(_cc_claude_procs)"
    if [ -n "$procs" ]; then
        _cc_err "Claude Code is running. Quit it first, or its in-memory token will be"
        _cc_err "written back over the swap when it exits. VS Code conversations count."
        printf '%s\n' "$procs" | while read -r n exe; do _cc_emit 2 $'\033[2m' "  $_cc_i_trace" "$n × $exe"; done
        return 1
    fi

    _cc_lock || return 1

    live="$(_cc_which)"
    if [ "$live" = "$target" ]; then
        _cc_unlock
        _cc_info "Already on $(_cc_who "$target")"
        return 0
    fi

    # tokens refresh in the background, so save the live one before leaving,
    # but only when the live account is still the one we recorded
    if [ -n "$live" ] && [ -d "$CC_HOME/profiles/$live" ]; then
        if [ "$(_cc_live_email)" = "$(_cc_profile_email "$live")" ]; then
            _cc_capture "$live" >/dev/null || _cc_warn "Could not refresh stored token for '$live'"
        else
            _cc_warn "Live account does not match profile '$live', skipping capture"
        fi
    fi

    # snapshot for rollback
    snap_cred="$(mktemp)"; snap_json="$(mktemp)"
    _cc_read_live_cred > "$snap_cred" 2>/dev/null
    [ -s "$CC_CLAUDE_JSON" ] && cp "$CC_CLAUDE_JSON" "$snap_json" 2>/dev/null

    if _cc_apply "$target"; then
        if [ -n "$live" ]; then
            _cc_ok "Switched $(_cc_val "$live") $_cc_i_arrow $(_cc_who "$target")"
        else
            _cc_ok "Switched to $(_cc_who "$target")"
        fi
    else
        rc=1
        _cc_err "Apply failed, rolling back"
        [ -s "$snap_cred" ] && _cc_write_live_cred < "$snap_cred" >/dev/null 2>&1
        [ -s "$snap_json" ] && cp "$snap_json" "$CC_CLAUDE_JSON" 2>/dev/null
        [ -n "$live" ] && printf '%s' "$live" > "$CC_HOME/live"
    fi

    rm -f "$snap_cred" "$snap_json"
    _cc_unlock
    return "$rc"
}

_cc_add() {
    local name="$1"
    _cc_valid_name "$name" || { _cc_err "Usage: cc add <profile>"; return 1; }
    mkdir -p "$CC_HOME/profiles/$name" || return 1
    _cc_ok "Created $(_cc_val "$name")"
    _cc_info "To populate it: run claude, log in as that account (/login if already signed in), quit, then:"
    _cc_trace "cc capture $name"
}

_cc_rm() {
    local name="$1" live
    _cc_valid_name "$name" || { _cc_err "Usage: cc rm <profile>"; return 1; }
    _cc_require_profile "$name" || return 1
    rm -rf "$CC_HOME/profiles/$name" || return 1
    live="$(_cc_which)"
    [ "$live" = "$name" ] && rm -f "$CC_HOME/live"
    _cc_ok "Removed $(_cc_val "$name")"
    _cc_trace "live credential untouched"
}

# profile names, sorted
_cc_ring() {
    find "$CC_HOME/profiles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sed 's#.*/##' | sort
}

# Escapes and glyphs stay outside the padded fields: printf pads by byte in
# bash, so a multibyte glyph inside %-14s would shift the column.
_cc_ls() {
    local live d name
    live="$(_cc_which)"
    [ -d "$CC_HOME/profiles" ] || { _cc_err "No profiles yet. Run: cc add <name>"; return 1; }
    printf '%s  %-14s %-30s %s%s\n' "$_cc_s_dim" PROFILE ACCOUNT STATUS "$_cc_s_end"
    _cc_ring | while IFS= read -r name; do
        d="$CC_HOME/profiles/$name"
        if [ "$name" = "$live" ]; then
            printf '%s%s%s %s%-14s%s ' "$_cc_s_ok" "$_cc_i_arrow" "$_cc_s_end" "$_cc_s_norm" "$name" "$_cc_s_end"
        else
            printf '  %-14s ' "$name"
        fi
        if [ ! -s "$d/credentials.json" ]; then
            printf '%s%-30s run: cc capture %s%s\n' "$_cc_s_dim" '(empty)' "$name" "$_cc_s_end"
        elif _cc_is_limited "$name"; then
            printf '%s%-30s%s %sspent, back in %s%s\n' "$_cc_s_dim" "$(_cc_profile_email "$name")" "$_cc_s_end" \
                "$_cc_s_attn" "$(_cc_human "$(( $(_cc_limit_until "$name") - $(_cc_now) ))")" "$_cc_s_end"
        else
            printf '%s%-30s%s %sready%s\n' "$_cc_s_dim" "$(_cc_profile_email "$name")" "$_cc_s_end" "$_cc_s_ok" "$_cc_s_end"
        fi
    done
}

_cc_kv() {   # key value [sgr]
    printf '%s%-15s:%s %s%s%s\n' "$_cc_s_dim" "$1" "$_cc_s_end" "${3:-}" "$2" "${3:+$_cc_s_end}"
}

_cc_doctor() {
    local live procs
    live="$(_cc_which)"
    procs="$(_cc_claude_procs)"
    _cc_kv 'cc home'      "$CC_HOME"
    _cc_kv 'claude home'  "$CC_CLAUDE_HOME"
    _cc_kv 'claude json'  "$CC_CLAUDE_JSON"
    _cc_kv 'backend'      "$(_cc_backend)"
    if [ -n "$live" ]; then _cc_kv 'live marker' "$live" "$_cc_s_norm"
    else                    _cc_kv 'live marker' '(none)' "$_cc_s_dim"; fi
    _cc_kv 'live account' "$(_cc_live_email)"
    if [ -n "$(_cc_read_live_cred)" ]; then _cc_kv 'live cred' present "$_cc_s_ok"
    else                                    _cc_kv 'live cred' absent "$_cc_s_err"; fi
    _cc_kv 'shared tree'  "$(_cc_shared)"
    _cc_kv 'account keys' "$CC_ACCOUNT_KEYS"
    if command -v jq >/dev/null 2>&1; then _cc_kv jq "$(command -v jq)"
    else                                   _cc_kv jq MISSING "$_cc_s_err"; fi
    if [ -n "$procs" ]; then
        _cc_kv 'claude running' "yes ($(printf '%s\n' "$procs" | awk '{ n += $1 } END { print n }'))" "$_cc_s_attn"
        printf '%s\n' "$procs" | while read -r n exe; do _cc_trace "$n × $exe"; done
    else
        _cc_kv 'claude running' no "$_cc_s_ok"
    fi
}

# ------------------------------------------------------------- rotation ----
#
# The point of this layer: with 3-4 subscriptions the question is never "which
# account" but "which account still has quota". Claude Code does not expose
# limit state to scripts, so the spent marker is set by you and expires on a
# timer.

_cc_now() { date +%s; }

_cc_parse_dur() {   # 5h | 90m | 300s | 300
    local d="$1" n u
    case "$d" in
        *h) n="${d%h}"; u=3600 ;;
        *m) n="${d%m}"; u=60 ;;
        *s) n="${d%s}"; u=1 ;;
        *)  n="$d";     u=1 ;;
    esac
    case "$n" in *[!0-9]*|'') return 1 ;; esac
    printf '%s' "$((n * u))"
}

_cc_human() {       # seconds -> 4h07m / 12m / now
    local s="$1"
    if   [ "$s" -le 0 ];    then printf 'now'
    elif [ "$s" -lt 3600 ]; then printf '%dm' "$(( (s + 59) / 60 ))"
    else printf '%dh%02dm' "$((s / 3600))" "$(( (s % 3600) / 60 ))"
    fi
}

# The spent marker holds the epoch second the window ends. Every read goes
# through here, which reaps the marker once elapsed (or if malformed), so no
# caller ever sees a stale one.
_cc_limit_until() {
    local marker="$CC_HOME/profiles/$1/spent" until
    until="$(cat "$marker" 2>/dev/null)"
    [ -n "$until" ] || return 1
    case "$until" in *[!0-9]*) rm -f "$marker"; return 1 ;; esac
    [ "$until" -gt "$(_cc_now)" ] || { rm -f "$marker"; return 1; }
    printf '%s' "$until"
}

_cc_is_limited() { _cc_limit_until "$1" >/dev/null; }

_cc_mark_spent() {
    local name="${1:-$(_cc_which)}" dur="${2:-$CC_LIMIT_DEFAULT}" secs
    [ -n "$name" ] || { _cc_err "No live profile to mark"; return 1; }
    _cc_require_profile "$name" || return 1
    secs="$(_cc_parse_dur "$dur")" || { _cc_err "Bad duration '$dur' (try 5h, 90m, 300s)"; return 1; }
    printf '%s' "$(( $(_cc_now) + secs ))" > "$CC_HOME/profiles/$name/spent"
    _cc_ok "Marked $(_cc_val "$name") spent, back in $(_cc_human "$secs")"
}

_cc_unmark() {
    local name="${1:-$(_cc_which)}"
    if [ "$name" = "--all" ]; then
        _cc_ring | while IFS= read -r n; do rm -f "$CC_HOME/profiles/$n/spent"; done
        _cc_ok "Cleared all spent markers"
        return 0
    fi
    _cc_require_profile "$name" || return 1
    rm -f "$CC_HOME/profiles/$name/spent"
    _cc_ok "Cleared $(_cc_val "$name"), available again"
}

# Next usable profile in ring order, starting after the live one.
_cc_next_available() {
    local live ring rotated
    ring="$(_cc_ring)"
    [ -n "$ring" ] || return 1
    live="$(_cc_which)"
    if [ -n "$live" ] && printf '%s\n' "$ring" | grep -qx -- "$live"; then
        rotated="$(printf '%s\n' "$ring" | awk -v live="$live" '
            { a[NR] = $0; if ($0 == live) idx = NR }
            END { for (i = 1; i <= NR; i++) print a[((idx + i - 1) % NR) + 1] }')"
    else
        rotated="$ring"
    fi
    printf '%s\n' "$rotated" | while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ -s "$CC_HOME/profiles/$n/credentials.json" ] || continue
        _cc_is_limited "$n" && continue
        printf '%s\n' "$n"
        break
    done | head -n1
}

_cc_soonest() {
    local best='' best_t='' until
    _cc_ring | while IFS= read -r n; do
        until="$(_cc_limit_until "$n")"
        [ -n "$until" ] && printf '%s %s\n' "$until" "$n"
    done | sort -n | head -n1 | while read -r t n; do
        _cc_info "Earliest is $(_cc_val "$n") in $(_cc_human "$((t - $(_cc_now)))")"
    done
}

_cc_next() {
    local target
    target="$(_cc_next_available)"
    if [ -z "$target" ]; then
        _cc_err "Every profile is spent or empty"
        _cc_soonest
        return 1
    fi
    _cc_use "$target"
}

_cc_resume() {
    command -v "$CC_CLAUDE_BIN" >/dev/null 2>&1 \
        || { _cc_err "'$CC_CLAUDE_BIN' not found on PATH"; return 1; }
    "$CC_CLAUDE_BIN" "$CC_RESUME_FLAG" "$@"
}

# go: resume here, rotating first only if the live sub is spent
_cc_go() {
    local live
    live="$(_cc_which)"
    if [ -z "$live" ] || _cc_is_limited "$live"; then
        _cc_next || return 1
    fi
    _cc_resume "$@"
}

# flip: this one is out of quota. Mark it, rotate, pick the session back up.
_cc_flip() {
    local live
    live="$(_cc_which)"
    [ -n "$live" ] && _cc_mark_spent "$live" "$CC_LIMIT_DEFAULT" >/dev/null
    _cc_next || return 1
    _cc_resume "$@"
}

# ------------------------------------------------- concurrent (linked) env ----
#
# Optional. Gives a profile its own CLAUDE_CONFIG_DIR so several subs can run
# at once in different terminals, with transcripts and project config symlinked
# back to one shared tree so --continue still sees everything.
# Only works if CLAUDE_CONFIG_DIR actually isolates auth on your install.
# See "Concurrent mode" in the README for the test.

_cc_shared() { printf '%s' "${CC_SHARED:-$CC_CLAUDE_HOME}"; }

_cc_link() {
    local name="$1" dir shared
    shared="$(_cc_shared)"
    _cc_valid_name "$name" || { _cc_err "Usage: cc link <profile>"; return 1; }
    dir="$CC_HOME/envs/$name"
    mkdir -p "$dir" || return 1
    _cc_words "$CC_LINK_PATHS" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -e "$shared/$rel" ] || continue
        [ -e "$dir/$rel" ] && continue
        ln -s "$shared/$rel" "$dir/$rel" 2>/dev/null
    done
    _cc_ok "Linked env at $(_cc_val "$dir")"
    _cc_trace "eval \"\$(cc env $name)\""
}

_cc_env() {
    local name="$1" dir
    _cc_valid_name "$name" || { _cc_err "Usage: cc env <profile>"; return 1; }
    dir="$CC_HOME/envs/$name"
    [ -d "$dir" ] || { _cc_err "No linked env for '$name'. Run: cc link $name"; return 1; }
    printf 'export CLAUDE_CONFIG_DIR=%s\n' "$dir"
}

# help rows: bold command, plain args, description at a fixed column
_cc_row() {
    local cmd="$1" args="$2" desc="$3" plain pad
    plain="  $cmd${args:+ $args}"
    printf -v pad '%*s' $(( 24 - ${#plain} )) ''
    printf '  %s%s%s%s%s%s\n' "$_cc_s_norm" "$cmd" "$_cc_s_end" "${args:+ $args}" "$pad" "$desc"
}

_cc_usage() {
    printf '%s cc-switch %s\n' "$_cc_s_brand" "$_cc_s_end"
    printf '  %sRotate Claude Code subscriptions without losing the thread.%s\n' "$_cc_s_dim" "$_cc_s_end"
    _cc_section 'RUNNING OUT OF QUOTA'
    _cc_row 'cc flip'    '[args]'      'Mark this sub spent, rotate to the next, resume here'
    _cc_row 'cc go'      '[args]'      'Resume here, rotating first only if this sub is spent'
    _cc_row 'cc next'    ''            'Rotate to the next sub with quota, do not launch'
    _cc_row 'cc spent'   '[p] [dur]'   'Mark a sub spent (default 5h)'
    _cc_row 'cc clear'   '[p|--all]'   'Clear a spent marker early'
    _cc_section 'PROFILES'
    _cc_row 'cc use'     '<profile>'   'Switch the live credential (auto-saves the outgoing one)'
    _cc_row 'cc add'     '<profile>'   'Create an empty profile'
    _cc_row 'cc capture' '[profile]'   'Snapshot the live credential into a profile'
    _cc_row 'cc ls'      ''            "List profiles with quota state, $_cc_i_arrow marks live"
    _cc_row 'cc which'   ''            'Print the live profile name'
    _cc_row 'cc rm'      '<profile>'   'Delete a stored profile'
    _cc_row 'cc doctor'  ''            'Resolved paths, backend, live identity'
    _cc_section 'CONCURRENT MODE (OPTIONAL)'
    _cc_row 'cc link'    '<profile>'   'Build a CLAUDE_CONFIG_DIR env with shared transcripts'
    # shellcheck disable=SC2016  # literal: the user runs it
    _cc_row 'cc env'     '<profile>'   'Print the export line: eval "$(cc env work)"'
    _cc_section 'ALIASES'
    printf '  %snew=add  sync=capture  list|status=ls  limit=spent  unspent=clear%s\n' "$_cc_s_dim" "$_cc_s_end"
    printf '  %scurrent=which  remove=rm%s\n\n' "$_cc_s_dim" "$_cc_s_end"
    printf '%s%s%s Quit Claude Code before switching, VS Code conversations included. It holds the token in memory.\n' \
        "$_cc_s_attn" "$_cc_i_warn" "$_cc_s_end"
}

cc() {
    local cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    _cc_style
    case "$cmd" in
        use)            _cc_need jq || return 1; _cc_use "$@" ;;
        add|new)        _cc_add "$@" ;;
        capture|sync)   _cc_need jq || return 1; _cc_capture "$@" ;;
        ls|list|status) _cc_need jq || return 1; _cc_ls ;;
        next)           _cc_need jq || return 1; _cc_next ;;
        flip)           _cc_need jq || return 1; _cc_flip "$@" ;;
        go)             _cc_need jq || return 1; _cc_go "$@" ;;
        spent|limit)    _cc_mark_spent "$@" ;;
        clear|unspent)  _cc_unmark "$@" ;;
        link)           _cc_link "$@" ;;
        env)            _cc_env "$@" ;;
        which|current)  _cc_which ;;
        rm|remove)      _cc_rm "$@" ;;
        doctor)         _cc_doctor ;;
        ''|-h|--help|help) _cc_usage ;;
        *)              _cc_err "Unknown command '$cmd'"; _cc_usage; return 1 ;;
    esac
}

# Convenience aliases. Override CC_NO_ALIASES=1 to skip.
if [ -z "${CC_NO_ALIASES:-}" ]; then
    alias c1='cc use main'
    alias c2='cc use backup'
fi
