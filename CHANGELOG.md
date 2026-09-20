# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-09-20

### Added

- `cc use|add|capture|ls|which|rm|doctor` with a sourceable shell function and
  a `bin/cc-switch` wrapper for scripts.
- macOS Keychain and file credential backends with automatic detection.
- Keychain writes routed through `security -i` so tokens stay out of `argv`,
  with a verified readback and an argv fallback.
- Auto-capture of the outgoing profile on switch, guarded by an identity match
  so a manual `/login` cannot overwrite a stored token with the wrong one.
- Rollback of the live credential and `~/.claude.json` if an apply fails.
- Refusal to switch while Claude Code is running.
- Directory lock with stale-lock recovery.
- Prompt integrations for zsh, Powerlevel10k, and Starship, plus a Claude Code
  statusline that reads the state file rather than an environment variable.
- Test suite covering the round trip, background-refresh capture, drift
  detection, guards, and file permissions.
