# Live profile in the right prompt. Reads the state file rather than an env
# var, because there is exactly one live credential on the machine and a
# per-shell variable would lie to you the moment you open a second tab.
autoload -Uz add-zsh-hook
_cc_rprompt() {
    local p
    p="$(cat "${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}/live" 2>/dev/null)"
    if [[ -n "$p" ]]; then RPROMPT="%F{242}cc:${p}%f"; else RPROMPT=""; fi
}
add-zsh-hook precmd _cc_rprompt
