# Add `cc_account` to POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS, then source this
# from ~/.p10k.zsh. The segment has two states: READY while the live profile
# has quota, SPENT once it is marked spent. Colours per state below.
zmodload zsh/datetime
function prompt_cc_account() {
    local dir="${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}" p ends
    [[ -r "$dir/live" ]] && p="$(<"$dir/live")"
    [[ -n "$p" ]] || return
    [[ -r "$dir/profiles/$p/spent" ]] && ends="$(<"$dir/profiles/$p/spent")"
    if [[ "$ends" == <-> && "$ends" -gt "$EPOCHSECONDS" ]]; then
        p10k segment -s SPENT -t "$p spent"
    else
        p10k segment -s READY -t "$p"
    fi
}
typeset -g POWERLEVEL9K_CC_ACCOUNT_READY_FOREGROUND=76
typeset -g POWERLEVEL9K_CC_ACCOUNT_READY_BACKGROUND=237
typeset -g POWERLEVEL9K_CC_ACCOUNT_SPENT_FOREGROUND=0
typeset -g POWERLEVEL9K_CC_ACCOUNT_SPENT_BACKGROUND=178
