# cc-switch

Rotate between Claude Code subscriptions without losing the thread.

The usual way to run two subscriptions is to toggle `CLAUDE_CONFIG_DIR`. That
moves everything: transcripts, history, `CLAUDE.md`, MCP servers, settings.
You end up with two half-populated environments, and `claude --resume` sees
only half your sessions.

cc-switch swaps the credential and nothing else. One `~/.claude`, one history,
one config. A switch changes only the live OAuth token and the `oauthAccount`
block in `~/.claude.json`.

```
$ cc ls
* work           alice@example.com    spent, back in 3h12m
  personal       bob@example.com      ready
  client         carol@example.com    ready

$ cc flip
cc: 'work' marked spent, back in 5h00m
cc: now 'personal' (bob@example.com)
[claude resumes the session you were in]
```

`cc flip` is the whole tool. This sub is spent. Move to the next one with
quota. Pick the conversation back up in the same directory.

> [!WARNING]
> Quit Claude Code before you switch. It holds the token in memory and
> rewrites `~/.claude.json` while it runs, so a switch from outside is a
> clobber. `cc use` refuses if it finds a running `claude` process.

## Install

Needs `bash` or `zsh`, `jq`, and Claude Code. macOS and Linux.

```bash
git clone https://github.com/jv-k/cc-switch ~/.local/share/cc-switch
~/.local/share/cc-switch/install.sh    # appends a source line to your rc file
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
claude                 # signed in as account A already? quit
cc capture main

cc add backup
claude                 # /login as account B, then quit
cc capture backup

cc ls
```

`c1` and `c2` are aliases for `cc use main` and `cc use backup`. Set
`CC_NO_ALIASES=1` before you source the file to skip them.

## Usage

### A sub runs out

```bash
cc flip          # mark this sub spent, rotate, resume here
cc go            # resume here, rotate first only if this sub is spent
cc next          # rotate, do not launch
cc spent [p] 2h  # mark a sub spent for a custom window
cc clear --all   # clear every marker
```

`flip` and `go` pass extra arguments through: `cc go --model opus`.

Resume is `claude --continue`, the most recent session in the current
directory. There is one `projects/` tree, so the fresh sub sees the spent
sub's transcript as its own.

Claude Code does not expose limit state, so you set the spent marker yourself.
It clears after five hours by default. That is a guess at the rolling window,
not a reading of your quota. Weekly caps are not modelled.

### Run subs side by side

To keep every sub live in its own terminal, give each one a
`CLAUDE_CONFIG_DIR` with the shared state symlinked back:

```bash
cc link work
eval "$(cc env work)"    # in that terminal only
claude
```

`cc link` symlinks `projects`, `history.jsonl`, `todos`, `CLAUDE.md`, `agents`,
`commands`, `skills`, and `plugins` back to `~/.claude`. `--continue` sees every
session from any terminal. Settings and credentials stay per-env. Change the
list with `CC_LINK_PATHS`.

This works only if `CLAUDE_CONFIG_DIR` isolates auth on your install. Some
macOS builds keep OAuth in one shared Keychain item that the variable does not
scope. Test first:

```bash
mkdir -p /tmp/cc-probe
CLAUDE_CONFIG_DIR=/tmp/cc-probe claude   # /login as a second account, then quit
ls /tmp/cc-probe/.credentials.json       # present means isolation works
```

No file means your install is Keychain-backed. Use serial rotation instead. It
swaps the Keychain item directly and works either way.

## Commands

| Command | Description |
| --- | --- |
| `cc flip [args]` | Mark the live sub spent, rotate, resume in this directory. |
| `cc go [args]` | Resume here. Rotate first only if the live sub is spent. |
| `cc next` | Rotate to the next sub with quota. Does not launch. |
| `cc spent [p] [dur]` | Mark a sub spent. Default `5h`. Accepts `90m`, `300s`. |
| `cc clear [p\|--all]` | Clear a spent marker early. |
| `cc use <profile>` | Switch the live credential. Saves the outgoing one first. |
| `cc add <profile>` | Create an empty profile. |
| `cc capture [profile]` | Snapshot the live credential into a profile. Defaults to the live one. |
| `cc ls` | List profiles with quota state. `*` marks live. |
| `cc which` | Print the live profile name. For prompts and scripts. |
| `cc rm <profile>` | Delete a stored profile. Leaves the live credential alone. |
| `cc doctor` | Resolved paths, detected backend, live identity. |
| `cc link <profile>` | Build a `CLAUDE_CONFIG_DIR` env with shared transcripts. |
| `cc env <profile>` | Print the export line for a linked env. |

Aliases: `new`=`add`, `sync`=`capture`, `list`/`status`=`ls`, `limit`=`spent`,
`unspent`=`clear`, `current`=`which`, `remove`=`rm`.

## Prompt and statusline

Drop-in snippets in `prompt/`:

- `zsh.zsh`: right prompt via a `precmd` hook
- `p10k.zsh`: a `cc_account` Powerlevel10k segment
- `starship.toml`: a `custom.cc` module
- `statusline.sh`: Claude Code statusline with directory, branch, profile, model, and context usage

All four read the state file, not an environment variable. There is one live
credential on the machine. A per-shell variable would show the wrong account
the moment you open a second tab.

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
| `CC_LIMIT_DEFAULT` | `5h` |
| `CC_CLAUDE_BIN` | `claude` |
| `CC_RESUME_FLAG` | `--continue` |
| `CC_SHARED` | `$CC_CLAUDE_HOME` |
| `CC_LINK_PATHS` | `projects history.jsonl todos CLAUDE.md agents commands skills plugins` |
| `CC_NO_ALIASES` | unset (defines `c1`, `c2`) |

## How it works

Claude Code keeps its OAuth token in the macOS Keychain, under the service
`Claude Code-credentials`, or in `~/.claude/.credentials.json`. Account
identity lives in the `oauthAccount` block of `~/.claude.json`. A profile is
those two things. `cc use` writes both. It merges the account block into
`~/.claude.json`, so per-project state survives. Keychain writes go through
`security -i`, so the token never lands in `argv`. Both files are snapshotted
before a switch and restored if the apply fails partway.

## Sharp edges

Prompt cache. Cache entries are server-side and partitioned by organization,
so every rotation is a full miss. The whole prefix is written again at
cache-write rates on the first message, against the sub you rotate into.
`/compact` before `cc flip` if the session is large.

Background refresh. `cc use` saves the live credential into the outgoing
profile before it switches, but only when the live account still matches
that profile. After a manual `/login`, run `cc capture`, or the stored token
goes stale.

Layout drift. Claude Code's on-disk layout moves between releases. `cc doctor`
confirms the paths and backend still resolve. If `~/.claude.json` carries
identity keys beyond `oauthAccount`, widen `CC_ACCOUNT_KEYS="oauthAccount userID"`.
If `cc use` misses a running process, widen `CC_PGREP_PATTERNS`.

Terms. Whether two subscriptions used this way sit inside Anthropic's terms
is your call to check.

## Tests

```bash
bash tests/run.sh
```

127 assertions against a throwaway `HOME` with the file backend. The Keychain
path is covered by CI on `macos-latest` and by `cc doctor`.

## Licence

MIT.
