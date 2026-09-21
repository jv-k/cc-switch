# cc-switch

Rotate between several Claude Code subscriptions without losing the thread.

The usual advice for running two Claude subscriptions is to toggle
`CLAUDE_CONFIG_DIR`. That works, but it moves *everything*: each account gets
its own `projects/` transcripts, its own `history.jsonl`, its own `CLAUDE.md`,
its own MCP servers and settings. You end up with two half-populated
environments and `claude --resume` that can only see half your sessions.

cc-switch swaps only the credential. One `~/.claude`. One history. One config.
The only thing that changes between profiles is which OAuth token is live and
which `oauthAccount` block sits in `~/.claude.json`. (Concurrent mode, below,
is the opt-in exception: a per-profile `CLAUDE_CONFIG_DIR` with the shared
tree symlinked back in.)

```
$ cc ls
  PROFILE        ACCOUNT                        STATUS
→ work           alice@example.com              spent, back in 3h12m
  personal       bob@example.com                ready
  client         carol@example.com              ready

$ cc flip
✔ Marked work spent, back in 5h00m
✔ Switched work → personal (bob@example.com)
[claude resumes the session you were in]
```

`cc flip` is the whole point: this sub is out, move to the next one with
quota, pick the conversation back up in the same directory. One command.

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

## Running out of quota

The workflow with three or four subscriptions is not "which account" but
"which account still has quota, and can it pick up where I left off".

```bash
cc flip          # this one is spent: mark it, rotate, resume here
cc go            # resume here, rotating first only if this sub is spent
cc next          # rotate without launching
cc spent [p] 2h  # mark a sub spent for a custom window
cc clear --all   # everything is back, forget the markers
```

Both `flip` and `go` pass extra arguments straight through, so
`cc go --model opus` works.

Resume is `claude --continue`, which picks up the most recent session in the
current directory. It works across a switch because there is only ever one
`projects/` tree. The fresh sub sees the spent sub's transcript as its own,
because as far as the filesystem is concerned it is. There is no server-side
session object to migrate.

Claude Code does not expose limit state to scripts, so the spent marker is
something you set rather than something cc-switch detects. It carries a
timestamp and clears itself when the window elapses, defaulting to five hours.
That is a guess at the rolling window, not a reading of your actual quota.
Weekly caps are not modelled at all.

## Concurrent mode

Serial rotation means quitting Claude Code to switch, because it holds the
token in memory. If you would rather have all your subs live at once in
different terminals, give each one its own `CLAUDE_CONFIG_DIR` with the shared
state symlinked back:

```bash
cc link work
eval "$(cc env work)"    # in that terminal only
claude
```

`cc link` symlinks `projects`, `history.jsonl`, `todos`, `CLAUDE.md`, `agents`,
`commands`, `skills`, and `plugins` back to `~/.claude`, so `--continue` still
sees every session regardless of which terminal you are in. Settings and
credentials stay per-env. Tune the list with `CC_LINK_PATHS`.

This only works if `CLAUDE_CONFIG_DIR` genuinely isolates auth on your install.
On macOS it may not: some builds keep OAuth in a single shared Keychain item
that the variable does not scope. Test before relying on it.

```bash
mkdir -p /tmp/cc-probe
CLAUDE_CONFIG_DIR=/tmp/cc-probe claude   # /login as a second account, then quit
ls /tmp/cc-probe/.credentials.json       # present means isolation works
```

If that file does not appear, your install is Keychain-backed and concurrent
mode is off the table. Use serial rotation, which swaps the Keychain item
directly and works either way.

## Commands

| Command | Description |
| --- | --- |
| `cc flip [args]` | Mark the live sub spent, rotate, resume in this directory. |
| `cc go [args]` | Resume here, rotating first only if the live sub is spent. |
| `cc next` | Rotate to the next sub with quota. Does not launch. |
| `cc spent [p] [dur]` | Mark a sub spent. Default `5h`. Accepts `90m`, `300s`. |
| `cc clear [p\|--all]` | Clear a spent marker early. |
| `cc link <profile>` | Build a `CLAUDE_CONFIG_DIR` env with shared transcripts. |
| `cc env <profile>` | Print the export line for a linked env. |
| `cc use <profile>` | Switch the live credential. Saves the outgoing one first. |
| `cc add <profile>` | Create an empty profile. |
| `cc capture [profile]` | Snapshot the live credential into a profile. Defaults to the live one. |
| `cc ls` | List profiles with quota state. `→` marks live. |
| `cc which` | Print the live profile name. For prompts and scripts. |
| `cc rm <profile>` | Delete a stored profile. Leaves the live credential alone. |
| `cc doctor` | Resolved paths, detected backend, live identity. |

Aliases: `new`→`add`, `sync`→`capture`, `list`/`status`→`ls`, `limit`→`spent`,
`unspent`→`clear`, `current`→`which`, `remove`→`rm`.

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
- `p10k.zsh` — a `cc_account` Powerlevel10k segment with `READY` and `SPENT`
  states
- `starship.toml` — `custom.cc` and `custom.cc_spent` modules; a custom module
  has one style, so quota state takes two with complementary `when` checks
- `statusline.sh` — Claude Code statusline showing directory, branch, profile,
  model, and context usage

All four read the state file, so they stay correct even if you switch in
another tab while a session is open, and they read the spent marker too: the
profile shows green while it has quota and yellow once it is marked spent
(the statusline adds the time to reset).

## What it does not solve

Prompt caching. Cache entries are server-side and partitioned by organization,
so each subscription is its own cache namespace and every rotation is a
guaranteed full miss. Nothing local changes that.

The cost lands on the sub you rotate *into*. Resuming a long session re-writes
the entire prefix — system prompt, `CLAUDE.md`, tool definitions, and the whole
replayed transcript — at cache-write rates, before the model does any work. On
a 150K-token context that is a six-figure token charge against the fresh sub's
window on the first message. `/compact` before `cc flip` if the session is
large. When you are flipping because you hit a limit the cache was already
gone, so the timing is mostly academic, but do not build a habit of bouncing
between subs mid-task.

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
| `CC_LIMIT_DEFAULT` | `5h` |
| `CC_CLAUDE_BIN` | `claude` |
| `CC_RESUME_FLAG` | `--continue` |
| `CC_SHARED` | `$CC_CLAUDE_HOME` |
| `CC_LINK_PATHS` | `projects history.jsonl todos CLAUDE.md agents commands skills plugins` |
| `CC_NO_ALIASES` | unset (defines `c1`, `c2`) |

Output is coloured on a terminal and plain when piped. `NO_COLOR` (any value)
turns it off; `CLICOLOR_FORCE=1` or `FORCE_COLOR=1` turns it on without a
terminal, for `| less -R`. stdout and stderr are decided separately, so
`cc use x 2>log` colours the terminal but not the log. `cc which` and `cc env`
are never styled: they are meant for prompts and `eval`.

## Tests

```bash
bash tests/run.sh
```

109 assertions against a throwaway `HOME` with the file backend, covering the
switch round trip, background-refresh capture, drift detection, ring rotation
with wrap-around and all-spent, marker expiry and reaping, `go`/`flip` against
a stub `claude` binary, linked-env symlinking, command aliases, the colour
gate and that styling adds no text, message wording, the prompt snippets'
quota state (statusline and Starship `when` checks in bash, zsh and p10k under
zsh when present) and their agreement with the library on `CC_HOME`, and the
running-process, lock, and permission guards. The Keychain path cannot be exercised
off macOS and is covered by CI on `macos-latest` plus `cc doctor`.

## Licence

MIT.
