#!/usr/bin/env bash
# Apprentice plugin — one driver script, two hook entry points:
#   apprentice.sh toggle   UserPromptSubmit (sync): /apprentice [on|off] edits the flag file
#   apprentice.sh narrate  MessageDisplay (sync): on a message's final flush,
#                          distill the new transcript, narrate it, and return
#                          displayContent = delta + blurbs so the narration
#                          renders directly beneath the message it describes.
#                          Display-only: the stored message and what the model
#                          sees are untouched.
#
# The .apprentice flag file sits in the project root and lists enabled session
# ids, one per line; every entry point self-filters and exits fast when
# apprentice mode is off for the session.
set -uo pipefail

# Recursion guard: the narrator's own headless session must not re-trigger us.
[ -n "${APPRENTICE_NARRATOR:-}" ] && exit 0

mode=${1:-}
input=$(cat)
field() { printf '%s' "$input" | jq -r "$1"; }

# MessageDisplay fires per flush of streamed lines; only the final flush (which
# may carry an empty delta) is our cue to narrate. Bail before any other work.
if [ "$mode" = narrate ]; then
  [ "$(field '.final // empty')" = "true" ] || exit 0
  [ -z "$(field '.agent_id // empty')" ] || exit 0   # don't narrate subagent streams
fi

cwd=$(field '.cwd // empty')
session=$(field '.session_id // "default"')
# Per-session state lives under the user's runtime dir (or /tmp) — ephemeral
# by design: the OS clears it, so the plugin never needs to delete anything.
runtime_base="${XDG_RUNTIME_DIR:-/tmp/claude-$(id -u)}"
state_root="$runtime_base/apprentice"
state_dir="$state_root/$session"

# The payload cwd follows the shell, which drifts as the agent cd's into
# subdirectories — walk up to find the project's .apprentice flag file.
flag=""
d="$cwd"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.apprentice" ]; then flag="$d/.apprentice"; break; fi
  d=${d%/*}
done

# Boxed user-facing message via hook systemMessage JSON — toggle feedback only.
# UserPromptSubmit plain stdout would leak into the agent's context, so any
# output there must be recognized hook JSON like this.
say() {
  jq -n --arg m "------------  Apprentice ------------
$1
-------------------------------------" '{systemMessage: ("\n" + $m)}'
}

# One narrator per session at a time. Reclaim locks older than 10 min in case
# a run died without cleanup; returns non-zero while the lock is held.
grab_lock() {
  lock_dir="$state_dir/lock"
  mkdir "$lock_dir" 2>/dev/null && return 0
  if [ -n "$(find "$lock_dir" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$lock_dir" 2>/dev/null
    mkdir "$lock_dir" 2>/dev/null && return 0
  fi
  return 1
}

# Distill transcript bytes past the cursor and run the narrator over them.
# Sets $out to the fresh blurbs, or '' when there is nothing new or the
# model answers SKIP. Caller must hold the lock.
run_narrator() {
  out=""
  transcript=$(field '.transcript_path // empty')
  [ -f "$transcript" ] || return 0
  offset_file="$state_dir/offset"
  offset=$(cat "$offset_file" 2>/dev/null || echo 0)
  size=$(stat -c %s "$transcript" 2>/dev/null || echo 0)
  # If the transcript shrank (file replaced), resync the cursor instead of
  # waiting forever for it to outgrow a stale offset.
  if [ "$size" -lt "$offset" ]; then
    echo "$size" > "$offset_file"
    return 0
  fi
  [ "$size" -gt "$offset" ] || return 0

  # Distill the new JSONL lines, each prefixed with its source (claude:,
  # user:, tool-call:, tool-result:). All four always reach the narrator;
  # what gets narrated vs. treated as context is decided in narrator-prompt.md.
  # fromjson? skips any partially-written trailing line.
  chunk=$(tail -c +"$((offset + 1))" "$transcript" | jq -Rrc '
    fromjson?
    | if .type == "assistant" then
        (.message.content[]?
         | if .type == "text" then "claude: " + .text
           elif .type == "tool_use" then "tool-call: " + .name + " " + (.input | tostring | .[0:500])
           else empty end)
      elif .type == "user" then
        (if (.message.content | type) == "string" then "user: " + .message.content[0:300]
         else (.message.content[]?
               | if .type == "tool_result" then "tool-result: " + ((.content | tostring) | .[0:400])
                 else empty end)
         end)
      else empty end' 2>/dev/null)

  # Cap the slice so a backlog (e.g. after a narration gap) can't turn into
  # a multi-minute narrator call; keep the most recent activity.
  chunk=$(printf '%s' "$chunk" | tail -c 16000)
  if [ -z "$chunk" ]; then
    echo "$size" > "$offset_file"
    return 0
  fi

  # The narrator keeps one continued conversation per main session (resume id
  # in narrator-session), so it remembers what it already explained and
  # accumulates task context. Run claude from the shared apprentice root so
  # every narrator transcript lands in a single ~/.claude/projects entry
  # instead of cluttering the main project's session list.
  sid_file="$state_dir/narrator-session"
  sid=$(cat "$sid_file" 2>/dev/null || true)
  resp=""
  if [ -n "$sid" ]; then
    resp=$(printf 'NEW ACTIVITY:\n%s\n' "$chunk" |
      { cd "$state_root" && APPRENTICE_NARRATOR=1 claude -p 'Narrate the new activity per your instructions.' --resume "$sid" --model sonnet --output-format json 2>/dev/null; }) || resp=""
  fi
  if [ -z "$resp" ]; then
    # First narration of the session (or the stored session is gone, e.g.
    # after a reboot): start fresh with the full instructions.
    narrator_prompt=$(cat "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/scripts/narrator-prompt.md")
    resp=$(printf 'NEW ACTIVITY:\n%s\n' "$chunk" |
      { cd "$state_root" && APPRENTICE_NARRATOR=1 claude -p "$narrator_prompt" --model sonnet --output-format json 2>/dev/null; }) || resp=""
  fi
  [ -n "$resp" ] || return 0
  # Advance the cursor only once the narrator has answered: the harness aborts
  # this hook if the next assistant message starts streaming before we finish,
  # and an unadvanced cursor lets that slice ride along with the next flush
  # instead of being lost.
  echo "$size" > "$offset_file"
  out=$(printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null)
  # Resume can fork to a new session id — always store the latest.
  new_sid=$(printf '%s' "$resp" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$new_sid" ] && printf '%s\n' "$new_sid" > "$sid_file"
  case "$out" in SKIP*) out="" ;; esac
}

case "$mode" in

toggle)
  # UserPromptSubmit fires before the agent sees the prompt, and hooks aren't
  # gated by permission modes, so this works even in plan mode.
  # Match "/apprentice" as the first word so "/apprentice here's my prompt"
  # also enables; only the literal argument "off" disables.
  read -r cmd arg _ <<< "$(field '.prompt // empty')"
  if [ "${cmd:-}" = "/apprentice" ]; then
    if [ "${arg:-}" = "off" ]; then
      [ -n "$flag" ] && rm -f "$flag"
      say "Apprentice mode disabled."
    else
      f=${flag:-$cwd/.apprentice}
      grep -qxF "$session" "$f" 2>/dev/null || echo "$session" >> "$f"
      say 'Apprentice mode enabled: a second model will narrate concepts from this session in notes appended below Claude'\''s replies. Turn it off with "/apprentice off".'
    fi
  fi
  ;;

narrate)
  [ -n "$flag" ] && grep -qxF "$session" "$flag" 2>/dev/null || exit 0
  mkdir -p "$state_dir"
  # The /tmp fallback root is ours to lock down; XDG_RUNTIME_DIR already is.
  [ -n "${XDG_RUNTIME_DIR:-}" ] || chmod 700 "$runtime_base" 2>/dev/null
  # A previous message's narrator may still be running; wait up to 10s for it.
  # If the lock stays busy, exit silently — the cursor is untouched, so the
  # next message's final flush narrates this slice too.
  got_lock=""
  for _ in $(seq 1 20); do
    grab_lock && { got_lock=1; break; }
    sleep 0.5
  done
  [ -n "$got_lock" ] || exit 0
  trap 'rmdir "$lock_dir" 2>/dev/null' EXIT
  trap 'exit 143' TERM INT HUP
  run_narrator
  [ -n "$out" ] || exit 0
  # Replace the final delta with delta + blurbs; rendered as markdown, so the
  # blockquotes appear styled directly beneath the message.
  delta=$(field '.delta // ""')
  jq -n --arg d "$delta" --arg n "$out" \
    '{hookSpecificOutput: {hookEventName: "MessageDisplay",
      displayContent: (if $d == "" then $n else $d + "\n\n" + $n end)}}'
  ;;
esac
