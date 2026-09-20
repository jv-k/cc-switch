# shellcheck shell=bash
#
# cc-switch — swap Claude Code accounts in place, keep one local state tree.
#
# Source from ~/.zshrc or ~/.bashrc:
#     source /path/to/cc-switch.sh
#
# Deliberately does NOT touch CLAUDE_CONFIG_DIR. One ~/.claude means one
# projects/ tree, one history.jsonl, one MCP config, one CLAUDE.md. The only
# thing that changes between profiles is which OAuth token is live.

# ---------------------------------------------------------------- config ----

: "${CC_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}"
: "${CC_CLAUDE_HOME:=$HOME/.claude}"
: "${CC_CLAUDE_JSON:=$HOME/.claude.json}"
: "${CC_KEYCHAIN_SERVICE:=Claude Code-credentials}"
: "${CC_ACCOUNT_KEYS:=oauthAccount}"   # space-separated top-level keys of ~/.claude.json
: "${CC_LOCK_TIMEOUT:=5}"              # seconds
: "${CC_PGREP_PATTERNS:=[c]laude/cli\.js [.]claude/local/claude}"  # space-separated, no spaces within a pattern

# ----------------------------------------------------------------- utils ----

_cc_err()  { printf 'cc: %s\n' "$*" >&2; }
_cc_warn() { printf 'cc: warning, %s\n' "$*" >&2; }
_cc_need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    _cc_err "missing required command: $1"
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
        _cc_warn "clearing stale lock"
        rmdir "$lock" 2>/dev/null
    fi
    while ! mkdir "$lock" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt $((CC_LOCK_TIMEOUT * 10)) ]; then
            _cc_err "another cc-switch operation is running ($lock)"
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
    _cc_warn "keychain stdin write failed, falling back to argv (briefly visible to ps)"
    security add-generic-password -U -s "$CC_KEYCHAIN_SERVICE" -a "$acct" -w "$payload" \
        >/dev/null 2>&1 || return 1
    [ "$(_cc_read_live_cred)" = "$payload" ]
}

_cc_write_live_cred() {
    local payload
    payload="$(cat)"
    [ -n "$payload" ] || { _cc_err "refusing to write an empty credential"; return 1; }
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
_cc_profile_email() { _cc_email_of "$CC_HOME/profiles/$1/account.json"; }

_cc_claude_running() {
    local hits
    command -v pgrep >/dev/null 2>&1 || return 1
    # split on whitespace explicitly: zsh does not word-split unquoted expansions
    hits="$(printf '%s\n' "$CC_PGREP_PATTERNS" | tr ' ' '\n' | while IFS= read -r p; do
                [ -n "$p" ] && pgrep -f "$p" 2>/dev/null
            done | wc -l | tr -d ' ')"
    [ "${hits:-0}" -gt 0 ]
}

# ------------------------------------------------------ capture and apply ----

_cc_capture() {
    local name="$1" dir cred
    _cc_valid_name "$name" || { _cc_err "bad profile name: '${name:-<empty>}'"; return 1; }
    dir="$CC_HOME/profiles/$name"
    mkdir -p "$dir" || return 1

    cred="$(_cc_read_live_cred)"
    [ -n "$cred" ] || { _cc_err "no live credential found (backend: $(_cc_backend))"; return 1; }
    printf '%s' "$cred" | _cc_write "$dir/credentials.json" || return 1

    if [ -s "$CC_CLAUDE_JSON" ]; then
        jq --arg keys "$CC_ACCOUNT_KEYS" \
           '($keys | split(" ")) as $k | with_entries(select(.key as $x | $k | index($x)))' \
           "$CC_CLAUDE_JSON" 2>/dev/null | _cc_write "$dir/account.json" \
            || _cc_warn "could not snapshot account keys from $CC_CLAUDE_JSON"
    fi

    printf '%s' "$name" > "$CC_HOME/live"
    return 0
}

_cc_apply() {
    local name="$1" dir="$CC_HOME/profiles/$1"
    [ -s "$dir/credentials.json" ] || {
        _cc_err "profile '$name' holds no credential. Run: cc capture $name"
        return 1
    }
    _cc_write_live_cred < "$dir/credentials.json" || return 1

    if [ -s "$dir/account.json" ] && [ -s "$CC_CLAUDE_JSON" ]; then
        jq -s '.[0] * .[1]' "$CC_CLAUDE_JSON" "$dir/account.json" 2>/dev/null \
            | _cc_write "$CC_CLAUDE_JSON" \
            || { _cc_err "failed to merge account metadata into $CC_CLAUDE_JSON"; return 1; }
    fi

    printf '%s' "$name" > "$CC_HOME/live"
    return 0
}

# -------------------------------------------------------------- commands ----

_cc_use() {
    local target="$1" live rc=0 snap_cred snap_json
    _cc_need jq || return 1
    _cc_valid_name "$target" || { _cc_err "usage: cc use <profile>"; return 1; }
    [ -d "$CC_HOME/profiles/$target" ] || { _cc_err "unknown profile '$target'"; return 1; }

    if _cc_claude_running; then
        _cc_err "claude is running. Quit it first, or its in-memory token will be"
        _cc_err "written back over the swap when it exits."
        return 1
    fi

    _cc_lock || return 1

    live="$(cat "$CC_HOME/live" 2>/dev/null)"
    if [ "$live" = "$target" ]; then
        _cc_unlock
        printf "cc: already '%s' (%s)\n" "$target" "$(_cc_profile_email "$target")"
        return 0
    fi

    # tokens refresh in the background, so save the live one before leaving,
    # but only when the live account is still the one we recorded
    if [ -n "$live" ] && [ -d "$CC_HOME/profiles/$live" ]; then
        if [ "$(_cc_live_email)" = "$(_cc_profile_email "$live")" ]; then
            _cc_capture "$live" >/dev/null || _cc_warn "could not refresh stored token for '$live'"
        else
            _cc_warn "live account does not match profile '$live', skipping capture"
        fi
    fi

    # snapshot for rollback
    snap_cred="$(mktemp)"; snap_json="$(mktemp)"
    _cc_read_live_cred > "$snap_cred" 2>/dev/null
    [ -s "$CC_CLAUDE_JSON" ] && cp "$CC_CLAUDE_JSON" "$snap_json" 2>/dev/null

    if _cc_apply "$target"; then
        printf "cc: now '%s' (%s)\n" "$target" "$(_cc_profile_email "$target")"
    else
        rc=1
        _cc_err "apply failed, rolling back"
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
    _cc_valid_name "$name" || { _cc_err "usage: cc add <profile>"; return 1; }
    mkdir -p "$CC_HOME/profiles/$name" || return 1
    cat <<MSG
cc: created '$name'. To populate it:
    1. claude              # log in as that account (/login if already signed in)
    2. quit claude
    3. cc capture $name
MSG
}

_cc_rm() {
    local name="$1" live
    _cc_valid_name "$name" || { _cc_err "usage: cc rm <profile>"; return 1; }
    [ -d "$CC_HOME/profiles/$name" ] || { _cc_err "unknown profile '$name'"; return 1; }
    rm -rf "$CC_HOME/profiles/$name" || return 1
    live="$(cat "$CC_HOME/live" 2>/dev/null)"
    [ "$live" = "$name" ] && rm -f "$CC_HOME/live"
    printf "cc: removed '%s' (live credential untouched)\n" "$name"
}

_cc_ls() {
    local live d name mark
    live="$(cat "$CC_HOME/live" 2>/dev/null)"
    [ -d "$CC_HOME/profiles" ] || { _cc_err "no profiles yet. Run: cc add <name>"; return 1; }
    find "$CC_HOME/profiles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | \
    while IFS= read -r d; do
        name="$(basename "$d")"
        if [ "$name" = "$live" ]; then mark='*'; else mark=' '; fi
        if [ -s "$d/credentials.json" ]; then
            printf '%s %-14s %s\n' "$mark" "$name" "$(_cc_profile_email "$name")"
        else
            printf '%s %-14s %s\n' "$mark" "$name" '(empty, run: cc capture)'
        fi
    done
}

_cc_which() { cat "$CC_HOME/live" 2>/dev/null; }

_cc_doctor() {
    printf 'cc home        : %s\n' "$CC_HOME"
    printf 'claude home    : %s\n' "$CC_CLAUDE_HOME"
    printf 'claude json    : %s\n' "$CC_CLAUDE_JSON"
    printf 'backend        : %s\n' "$(_cc_backend)"
    printf 'live marker    : %s\n' "$(_cc_which || echo '(none)')"
    printf 'live account   : %s\n' "$(_cc_live_email)"
    printf 'live cred      : %s\n' \
        "$([ -n "$(_cc_read_live_cred)" ] && echo present || echo absent)"
    printf 'account keys   : %s\n' "$CC_ACCOUNT_KEYS"
    printf 'jq             : %s\n' "$(command -v jq || echo MISSING)"
    printf 'claude running : %s\n' "$(_cc_claude_running && echo yes || echo no)"
}

_cc_usage() {
    cat <<'MSG'
cc-switch — swap Claude Code accounts in place

  cc use <profile>      switch the live credential (auto-saves the outgoing one)
  cc add <profile>      create an empty profile
  cc capture [profile]  snapshot the live credential into a profile
  cc ls                 list profiles, * marks live
  cc which              print the live profile name
  cc rm <profile>       delete a stored profile
  cc doctor             print resolved paths, backend, and live identity

Never switch while claude is running.
MSG
}

cc() {
    local cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in
        use)            _cc_use "$@" ;;
        add|new)        _cc_add "$@" ;;
        capture|sync)   _cc_need jq || return 1
                        local target="${1:-$(_cc_which)}"
                        _cc_capture "$target" \
                            && printf "cc: captured '%s' (%s)\n" \
                                 "$target" "$(_cc_profile_email "$target")" ;;
        ls|list)        _cc_ls ;;
        which|current)  _cc_which ;;
        rm|remove)      _cc_rm "$@" ;;
        doctor)         _cc_doctor ;;
        ''|-h|--help|help) _cc_usage ;;
        *)              _cc_err "unknown command '$cmd'"; _cc_usage; return 1 ;;
    esac
}

# Convenience aliases. Override CC_NO_ALIASES=1 to skip.
if [ -z "${CC_NO_ALIASES:-}" ]; then
    alias c1='cc use main'
    alias c2='cc use backup'
fi
