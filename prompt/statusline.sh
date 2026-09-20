#!/usr/bin/env bash
# Claude Code statusline. Wire it up in ~/.claude/settings.json:
#   { "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh" } }
#
# Reads the cc-switch state file, so it stays correct even if you switch
# profiles in another tab while this session is open.
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.workspace.current_dir // "."')"
model="$(printf '%s' "$input" | jq -r '.model.display_name // "?"')"
profile="$(cat "${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}/live" 2>/dev/null)"

cd "$cwd" 2>/dev/null || true
printf '\033[32m%s\033[0m' "$(basename "$cwd")"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf ' \033[36mgit:\033[0m\033[2m(\033[0m\033[35m%s\033[0m\033[2m)\033[0m' \
        "$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)"
fi

[ -n "$profile" ] && printf ' \033[2m|\033[0m \033[33m%s\033[0m' "$profile"
printf ' \033[2m|\033[0m %s' "$model"

usage="$(printf '%s' "$input" | jq '.context_window.current_usage // empty')"
if [ -n "$usage" ]; then
    cur="$(printf '%s' "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')"
    size="$(printf '%s' "$input" | jq '.context_window.context_window_size')"
    printf ' \033[2m|\033[0m \033[32m%dK/%dK\033[0m' $((cur / 1000)) $((size / 1000))
fi
printf '\n'
