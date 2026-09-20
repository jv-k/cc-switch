#!/usr/bin/env bash
# Appends the source line to your rc file. Does nothing else.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cc-switch.sh"
rc="${1:-}"

if [ -z "$rc" ]; then
    case "$(basename "${SHELL:-}")" in
        zsh)  rc="$HOME/.zshrc" ;;
        bash) rc="$HOME/.bashrc" ;;
        *)    echo "could not detect shell, pass the rc file: ./install.sh ~/.zshrc" >&2
              exit 1 ;;
    esac
fi

line="source \"$src\""
if grep -qF "$line" "$rc" 2>/dev/null; then
    echo "already installed in $rc"
else
    printf '\n# cc-switch\n%s\n' "$line" >> "$rc"
    echo "added to $rc"
fi

command -v jq >/dev/null 2>&1 || echo "note: jq is required and was not found on PATH" >&2
echo "open a new shell, then run: cc doctor"
