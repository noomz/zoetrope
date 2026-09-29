#!/usr/bin/env bash
# Print "<agent> <session-id>" for the pane the plugin was invoked from, or
# exit non-zero with the reason on stderr.
#
# The pane id comes from `focused_pane_id` in HERDR_PLUGIN_CONTEXT_JSON, never
# from HERDR_PANE_ID: in a pane command HERDR_PANE_ID is the plugin's own new
# pane, and asking Herdr about that one returns a pane with no agent. The
# context names the pane that was focused when the plugin was invoked, and it
# is the same field for an action and for a pane command.
#
# Herdr's Claude Code and Codex integrations report the native session id from
# a SessionStart hook (`pane.report_agent_session`), so `pane.get` carries
# `agent_session: {source, agent, kind: "id", value}` for both. That pair is
# all zoe needs. Nothing is guessed from the working directory; when Herdr has
# no id, the caller says so.
#
# A Claude session does not always live under `~/.claude`. Claude Code keeps its
# transcripts in the config directory, which is `$CLAUDE_CONFIG_DIR` when the
# agent was started with one, and account switchers (CCS and friends) point it
# at a per-account directory. So for Claude Code the transcript is looked for
# where the agent itself says it is (see `claude_transcript`), and its path is
# printed in place of the id when it is found; zoe opens a path and an id the
# same way. Everything else is unchanged.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-{\}}"

command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH, and the plugin reads Herdr's JSON with it" >&2; exit 1; }

pane_id=$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty')
[ -n "$pane_id" ] || { echo "no focused pane in the invocation context" >&2; exit 1; }

resp=$("$herdr" pane get "$pane_id" 2>&1) || { echo "herdr pane get failed: $resp" >&2; exit 1; }
err=$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null || true)
[ -z "$err" ] || { echo "herdr: $err" >&2; exit 1; }

# `pane.get` answers `{"result": {"pane": {...}, "type": "pane_info"}}`: the
# record is under `.result.pane`, not `.result` itself.
pane=$(printf '%s' "$resp" | jq '.result.pane // .result')
agent=$(printf '%s' "$pane" | jq -r '.agent_session.agent // .agent // empty')
kind=$(printf  '%s' "$pane" | jq -r '.agent_session.kind  // empty')
value=$(printf '%s' "$pane" | jq -r '.agent_session.value // empty')

case "$agent" in
  claude | codex) ;;
  "") echo "pane $pane_id has no agent: focus a Claude Code or Codex pane" >&2; exit 1 ;;
  *)  echo "agent '$agent' in pane $pane_id is not one zoe reads (Claude Code and Codex)" >&2; exit 1 ;;
esac

case "$kind" in
  id) ;;
  "") cat >&2 <<MSG
Herdr has no session id for this $agent pane.

  The id comes from the agent's SessionStart hook, which fires only when a
  session begins. So: install the integration if it is missing, then start the
  agent in that pane again. A session that was already running when the
  integration was installed never reports one.

    herdr integration install $agent    (herdr integration status lists them)
MSG
     exit 1 ;;
  *)  echo "Herdr reports a $kind for this $agent pane, and the plugin expects an id" >&2; exit 1 ;;
esac

# The value of an environment variable in another process's environment, as far
# as this user may read it. Linux answers from /proc; macOS from `ps`, where
# `e` asks for the environment and the extra `w` keeps it from being cut off.
env_value_of() {
  local pid="$1" name="$2"
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true
  else
    ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' || true
  fi | sed -n "s/^$name=//p" | head -1
}

# The config directory the pane's agent is running with, if it can be read.
#
# This process does not have `$CLAUDE_CONFIG_DIR` itself: Herdr spawned this
# pane from its server, and the server's environment is not the agent's, so a
# switcher that exported it for one agent never reaches here. The agent's own
# process does carry it, and `pane process-info` names the processes in the
# pane, so the variable is read from the agent instead of assumed. The pane
# shell is a fallback, for an agent that inherited a directory from the pane
# rather than choosing one.
claude_config_dir() {
  local pid dir pids
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && { printf '%s' "$CLAUDE_CONFIG_DIR"; return 0; }
  pids=$("$herdr" pane process-info --pane "$pane_id" 2>/dev/null \
    | jq -r '.result.process_info | (.foreground_processes[]?.pid, .shell_pid)' 2>/dev/null || true)
  for pid in $pids; do
    case "$pid" in '' | null) continue ;; esac
    dir=$(env_value_of "$pid" CLAUDE_CONFIG_DIR)
    [ -n "$dir" ] && { printf '%s' "$dir"; return 0; }
  done
  return 1
}

# The transcript of a session inside a config directory: Claude Code names the
# project directory after the working directory, which this does not need to
# reproduce — the id is unique, so any project directory holding it is the one.
transcript_of() {
  local dir="$1" id="$2" file
  for file in "$dir"/projects/*/"$id".jsonl; do
    [ -f "$file" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

# Claude Code first: hand over the transcript's own path when the config
# directory and the file are both there. Otherwise the id, which is what
# `~/.claude/projects` and the Codex layout answer to.
if [ "$agent" = claude ] \
  && dir=$(claude_config_dir) \
  && file=$(transcript_of "$dir" "$value"); then
  printf '%s %s\n' "$agent" "$file"
  exit 0
fi

printf '%s %s\n' "$agent" "$value"
