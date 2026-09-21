# Live profile in the right prompt. Reads the state file rather than an env
# var, because there is exactly one live credential on the machine and a
# per-shell variable would lie to you the moment you open a second tab.
# Green while the profile has quota, yellow once it is marked spent.
autoload -Uz add-zsh-hook
zmodload zsh/datetime
_cc_rprompt() {
    local dir="${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}" p ends
    [[ -r "$dir/live" ]] && p="$(<"$dir/live")"
    if [[ -z "$p" ]]; then RPROMPT=""; return; fi
    [[ -r "$dir/profiles/$p/spent" ]] && ends="$(<"$dir/profiles/$p/spent")"
    if [[ "$ends" == <-> && "$ends" -gt "$EPOCHSECONDS" ]]; then
        RPROMPT="%F{yellow}cc:${p} spent%f"
    else
        RPROMPT="%F{242}cc:%f%F{green}${p}%f"
    fi
}
add-zsh-hook precmd _cc_rprompt
