# Add `cc_account` to POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS, then source this
# from ~/.p10k.zsh.
function prompt_cc_account() {
    local p
    p="$(cat "${CC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cc-switch}/live" 2>/dev/null)"
    [[ -n "$p" ]] && p10k segment -t "$p"
}
typeset -g POWERLEVEL9K_CC_ACCOUNT_FOREGROUND=255
typeset -g POWERLEVEL9K_CC_ACCOUNT_BACKGROUND=237
