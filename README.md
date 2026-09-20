# cc-switch

Swap Claude Code accounts in place, without fragmenting your local state.

The usual advice for running two Claude subscriptions is to toggle
`CLAUDE_CONFIG_DIR`. That works, but it moves *everything*: each account gets
its own `projects/` transcripts, its own `history.jsonl`, its own `CLAUDE.md`,
its own MCP servers and settings. You end up with two half-populated
environments and `claude --resume` that can only see half your sessions.

cc-switch swaps only the credential. One `~/.claude`. One history. One config.
The only thing that changes between profiles is which OAuth token is live and
which `oauthAccount` block sits in `~/.claude.json`.

```
$ cc ls
  backup         bob@example.com
* main           alice@example.com

$ cc use backup
cc: now 'backup' (bob@example.com)
```

## Requirements

`bash` or `zsh`, `jq`, and Claude Code. macOS and Linux.

## Install

```bash
git clone https://github.com/jv-k/cc-switch ~/.local/share/cc-switch
~/.local/share/cc-switch/install.sh        # appends a source line to your rc file
exec $SHELL
cc doctor
```

Or add the line yourself:

```bash
source ~/.local/share/cc-switch/cc-switch.sh
```

## Setup

```bash
cc add main
claude                 # already signed in as account A? just quit
cc capture main

cc add backup
claude                 # /login as account B, then quit
cc capture backup

cc ls
```

`c1` and `c2` are aliased to `cc use main` and `cc use backup`. Set
`CC_NO_ALIASES=1` before sourcing to skip them.

## Commands

| Command | Description |
| --- | --- |
| `cc use <profile>` | Switch the live credential. Saves the outgoing one first. |
| `cc add <profile>` | Create an empty profile. |
| `cc capture [profile]` | Snapshot the live credential into a profile. Defaults to the live one. |
| `cc ls` | List profiles. `*` marks live. |
| `cc which` | Print the live profile name. For prompts and scripts. |
| `cc rm <profile>` | Delete a stored profile. Leaves the live credential alone. |
| `cc doctor` | Resolved paths, detected backend, live identity. |

## How it works

Claude Code keeps its OAuth token in one of two places, and cc-switch detects
which at runtime:

- macOS Keychain, as a generic password under the service `Claude Code-credentials`
- `~/.claude/.credentials.json`, on Linux and on macOS installs that do not use the Keychain

Account identity lives separately, in the `oauthAccount` block of
`~/.claude.json`. A profile is therefore two files: the credential payload and
a projection of the account keys. `cc use` writes both, merging the account
block into the existing `~/.claude.json` rather than replacing the file, so
per-project state survives untouched.

Keychain writes go through `security -i` rather than `-w <payload>`, so the
token never lands in `argv` where `ps` can see it. The write is verified by
reading it back, with a fallback to the argv form if the interactive parser
chokes on the JSON.

Switching is transactional. The live credential and `~/.claude.json` are
snapshotted before any write, and restored if the apply fails partway.

### Why a state file and not an environment variable

There is exactly one live credential on the machine. A per-shell environment
variable would claim otherwise the moment you open a second tab, and your
prompt would confidently show the wrong account. `cc which` reads
`$CC_HOME/live`, which is the truth.

## Prompt and statusline

Drop-in snippets are in `prompt/`:

- `zsh.zsh` — right prompt via a `precmd` hook
- `p10k.zsh` — a `cc_account` Powerlevel10k segment
- `starship.toml` — a `custom.cc` module
- `statusline.sh` — Claude Code statusline showing directory, branch, profile, model, and context usage

The statusline reads the state file, so it stays correct even if you switch in
another tab while a session is open.

## What it does not solve

Prompt caching. Cache entries are server-side and partitioned by organization,
so two subscriptions are two cache namespaces and every switch is a guaranteed
full miss. Nothing local can change that. The practical cost is that your next
turn re-writes the whole prefix — system prompt, `CLAUDE.md`, tool definitions,
and the entire replayed transcript — at cache-write rates. Switch at session
boundaries, and `/compact` first if the context is large.

Local transcripts are unaffected. Session resume is a pure local replay of a
JSONL file with no server-side session object, so a conversation started on one
account resumes cleanly on the other.

## Sharp edges

Never switch while Claude Code is running. It holds the token in memory and
rewrites `~/.claude.json` continuously, so a read-modify-write from outside is a
clobber. `cc use` refuses if it sees a running process, matched against
`CC_PGREP_PATTERNS`. Those patterns are a guess at the common install layouts
and are worth checking against `pgrep -fl node` on your machine.

Access tokens refresh in the background during a session. `cc use` captures the
live credential into the outgoing profile before switching away, but only when
the live account still matches what that profile recorded. If you `/login` by
hand, run `cc capture` afterwards or the stored token goes stale.

`CC_ACCOUNT_KEYS` defaults to `oauthAccount`. If your `~/.claude.json` carries
other identity-bearing top-level keys, diff the file between two logins and
widen the list:

```bash
export CC_ACCOUNT_KEYS="oauthAccount userID"
```

Claude Code's on-disk layout moves between releases. `cc doctor` is the fastest
way to confirm the paths and backend still resolve on your install.

Whether two subscriptions used this way sits inside Anthropic's terms is your
call to check, not a question this tool answers.

## Configuration

| Variable | Default |
| --- | --- |
| `CC_HOME` | `${XDG_CONFIG_HOME:-~/.config}/cc-switch` |
| `CC_CLAUDE_HOME` | `~/.claude` |
| `CC_CLAUDE_JSON` | `~/.claude.json` |
| `CC_KEYCHAIN_SERVICE` | `Claude Code-credentials` |
| `CC_ACCOUNT_KEYS` | `oauthAccount` |
| `CC_BACKEND` | auto-detected (`keychain` or `file`) |
| `CC_PGREP_PATTERNS` | Claude Code process patterns |
| `CC_LOCK_TIMEOUT` | `5` seconds |
| `CC_NO_ALIASES` | unset (defines `c1`, `c2`) |

## Tests

```bash
bash tests/run.sh
```

Runs against a throwaway `HOME` with the file backend, covering the switch
round trip, background-refresh capture, drift detection, the running-process
and lock guards, and file permissions. The Keychain path cannot be exercised
off macOS and is covered by CI on `macos-latest` plus `cc doctor`.

## Licence

MIT.
