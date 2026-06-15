#!/usr/bin/env bash
# Minimal Claude Code statusline. Renders: cwd · branch · model · ctx% · 5h% · agents · style
# Input: Claude Code session JSON on stdin.
# Adapted from macOS original for Linux (GNU date, /tmp paths, no iCloud canonicalization).

set -u

# Terminal width. Claude Code runs the statusline as a subprocess with no
# usable controlling terminal, so `stty size </dev/tty` fails and bash doesn't
# export $COLUMNS — leaving us blind to the real width. The reliable source is
# the multiplexer: when running inside tmux, ask the server for the actual pane
# width (works without a tty, since tmux is a separate process). Fall back to
# stty, then to "wide" (200) only when nothing else answers.
# Override with $STATUSLINE_COLS for testing or to force a width.
cols="${STATUSLINE_COLS:-}"
if [[ -z "$cols" && -n "${TMUX:-}" ]]; then
  if [[ -n "${TMUX_PANE:-}" ]]; then
    cols="$(tmux display-message -t "$TMUX_PANE" -p '#{pane_width}' 2>/dev/null)"
  else
    cols="$(tmux display-message -p '#{pane_width}' 2>/dev/null)"
  fi
fi
[[ -z "$cols" ]] && cols="$({ stty size </dev/tty | awk '{print $2}'; } 2>/dev/null)"
cols="${cols:-200}"
# Guard against non-numeric results from any of the sources above.
[[ "$cols" =~ ^[0-9]+$ ]] || cols=200

# Progressive-disclosure tiers — what gets shown at each width.
# Reference widths: phone-portrait ~40-55 · phone-landscape ~70-90
#                   iPad 11" portrait ~50-75 · iPad 11" landscape ~100-140
#                   laptop SSH ~100+ · laptop wide ~140+
#
# Tier 1 (always):  cwd, ctx %, 5h % w/ reset time           [phone portrait]
# Tier 2 (>=60):    + branch (name only), model              [phone landscape, iPad portrait]
# Tier 3 (>=100):   + bars before %, ctx/5h labels, diff, output style   [iPad landscape, laptop]
# Tier 4 (>=120):   + active agent indicator                 [laptop wide]
#
# 5h % always renders — its label flips to the local reset time (e.g. "5:30pm")
# when the JSON payload includes the reset epoch. Style is dropped on phones
# per user preference (the room is better spent on rate-limit info).
show_branch=0; show_model=0
show_diff=0; show_bars=0; show_style=0
show_agents=0
(( cols >= 60 ))  && { show_branch=1; show_model=1; }
(( cols >= 100 )) && { show_diff=1; show_bars=1; show_style=1; }
(( cols >= 120 )) && show_agents=1

input="$(cat)"

# One-time debug: dump JSON for inspection, then self-disable.
_debug_flag=~/.claude/.statusline-debug
if [[ -f "$_debug_flag" ]]; then
  printf '%s\n' "$input" > ~/.claude/.statusline-input.json
  rm -f "$_debug_flag"
fi

# ANSI helpers
ansi()  { printf '\033[%sm%s\033[0m' "$1" "$2"; }
dim()   { ansi 2 "$1"; }
sep()   { dim ' · '; }

# Threshold color for usage bars. Defaults match the context-window bands
# (green <41, yellow 41-65, red >=66) — aggressive because hitting the
# ceiling forces /compact or /clear. Pass explicit thresholds for bars
# whose limit auto-resets (e.g. 5h rate limit → 75/90).
threshold_color() {
  local n yellow_at red_at
  n=$(printf '%.0f' "${1:-0}")
  yellow_at="${2:-41}"
  red_at="${3:-66}"
  if   (( n >= red_at ))    ; then printf '31'
  elif (( n >= yellow_at )) ; then printf '33'
  else                             printf '32'
  fi
}

# 8-cell progress bar. Input: 0-100. Output: e.g. "███░░░░░"
bar() {
  local pct="${1:-0}" width=8 filled empty
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{ f=p*w/100; printf "%.0f", (f>w?w:(f<0?0:f)) }')
  empty=$(( width - filled ))
  local out=""
  while (( filled-- > 0 )); do out+="█"; done
  while (( empty-- > 0 )); do out+="░"; done
  printf '%s' "$out"
}

# Fields. jq stderr is silenced — Claude Code payloads occasionally contain
# raw control bytes inside strings (invalid per JSON spec, but they happen).
# When that occurs the field falls back to empty via `// ""` / `// empty`.
cwd="$(printf '%s' "$input"       | jq -r '.workspace.current_dir // .cwd // ""'    2>/dev/null)"
model="$(printf '%s' "$input"     | jq -r '.model.display_name // .model.id // ""'  2>/dev/null)"
style="$(printf '%s' "$input"     | jq -r '.output_style.name // ""'                2>/dev/null)"
ctx_pct_raw="$(printf '%s' "$input"   | jq -r '.context_window.used_percentage // empty' 2>/dev/null)"
five_h_pct="$(printf '%s' "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)"
five_h_resets="$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)"

# If the payload had embedded control bytes, jq parsing failed for every
# field above. Try once more after stripping control bytes — this loses
# whatever was in the rogue string but recovers the rest of the document.
if [[ -z "$cwd" && -z "$model" ]]; then
  _scrubbed="$(printf '%s' "$input" | tr -d '\000-\010\013\014\016-\037')"
  cwd="$(printf '%s' "$_scrubbed"       | jq -r '.workspace.current_dir // .cwd // ""'    2>/dev/null)"
  model="$(printf '%s' "$_scrubbed"     | jq -r '.model.display_name // .model.id // ""'  2>/dev/null)"
  style="$(printf '%s' "$_scrubbed"     | jq -r '.output_style.name // ""'                2>/dev/null)"
  ctx_pct_raw="$(printf '%s' "$_scrubbed"   | jq -r '.context_window.used_percentage // empty' 2>/dev/null)"
  five_h_pct="$(printf '%s' "$_scrubbed"    | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)"
  five_h_resets="$(printf '%s' "$_scrubbed" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)"
fi

# Drop the trailing model parenthetical, e.g. "Opus 4.8 (1M context)" -> "Opus 4.8".
# The suffix eats ~13 chars and overflows narrow (phone) widths; the base name
# is enough to orient. Matches the macOS statusline's behavior.
model="${model%% (*}"

# Format reset epoch to local "5:30pm" / "9am" (drops :00 on the hour).
# Server is typically UTC; we want the *user's* local TZ. Defaults to the
# system TZ; override with $STATUSLINE_TZ when SSHing from another TZ
# (e.g. STATUSLINE_TZ=America/New_York).
fmt_reset_time() {
  local epoch="$1" out
  if [[ -n "${STATUSLINE_TZ:-}" ]]; then
    out=$(TZ="$STATUSLINE_TZ" date -d "@$epoch" '+%-I:%M%p' 2>/dev/null) || return 1
  else
    out=$(date -d "@$epoch" '+%-I:%M%p' 2>/dev/null) || return 1
  fi
  out="${out//:00/}"
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}
five_h_label="5h"
if [[ -n "${five_h_resets:-}" ]]; then
  t="$(fmt_reset_time "$five_h_resets" 2>/dev/null)" && [[ -n "$t" ]] && five_h_label="$t"
fi

# Active subagents: a*.output symlinks whose target .jsonl was modified
# in the last 60 seconds. The tasks dir lives at
#   /tmp/claude-$UID/<project-slug>/<session-uuid>/tasks/
# Project slug = cwd with /, ., space, ~ all replaced by -.
active_agents=""
agent_names=""
agent_cache="$HOME/.claude/.statusline-agents.tsv"

resolve_agent_type() {
  local agent_id="$1" link="$2" hit target session_id proj_slug parent_jsonl agent_type
  if [[ -f "$agent_cache" ]]; then
    hit=$(awk -F'\t' -v id="$agent_id" '$1==id {print $2; exit}' "$agent_cache" 2>/dev/null)
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return; }
  fi
  target="$(readlink "$link" 2>/dev/null)"
  [[ -z "$target" || ! -f "$target" ]] && return
  # target = .../projects/<slug>/<session>/subagents/agent-<id>.jsonl
  session_id="$(basename "$(dirname "$(dirname "$target")")")"
  proj_slug="$(basename "$(dirname "$(dirname "$(dirname "$target")")")")"
  parent_jsonl="$HOME/.claude/projects/$proj_slug/$session_id.jsonl"
  [[ -f "$parent_jsonl" ]] || return
  agent_type="$(grep -F "\"agentId\":\"$agent_id\"" "$parent_jsonl" \
                | head -1 \
                | jq -r '.toolUseResult.agentType // empty' 2>/dev/null)"
  [[ -z "$agent_type" ]] && return
  printf '%s\t%s\n' "$agent_id" "$agent_type" >> "$agent_cache"
  printf '%s' "$agent_type"
}

if [[ -n "${cwd:-}" ]]; then
  slug="$(printf '%s' "$cwd" | sed 's|[/. ~]|-|g')"
  sess_root="/tmp/claude-$(id -u)/$slug"
  if [[ -d "$sess_root" ]]; then
    latest_session="$(/bin/ls -t "$sess_root" 2>/dev/null | head -1)"
    tasks_dir="$sess_root/$latest_session/tasks"
    if [[ -d "$tasks_dir" ]]; then
      types_collected=""
      while IFS= read -r link_path; do
        [[ -z "$link_path" ]] && continue
        orig_link="$tasks_dir/$(basename "$link_path")"
        aid="$(basename "$orig_link" .output)"
        t="$(resolve_agent_type "$aid" "$orig_link")"
        [[ -z "$t" ]] && t="?"
        types_collected+="$t"$'\n'
      done < <(find -L "$tasks_dir" -maxdepth 1 -name 'a*.output' \
               -newermt '60 seconds ago' -type f 2>/dev/null)
      active_agents=$(printf '%s' "$types_collected" | grep -c . || true)
      if [[ "${active_agents:-0}" -gt 0 ]]; then
        agent_names=$(printf '%s' "$types_collected" | sort | uniq -c | awk '
          { count=$1; $1=""; sub(/^ +/, ""); type=$0;
            sep=(NR==1 ? "" : ", ");
            if (count > 1) printf "%s%s×%d", sep, type, count;
            else           printf "%s%s",     sep, type
          }')
      else
        active_agents=""
      fi
    fi
  fi
fi

# ──────────────────────────────────────────────────────────────────────
# Display cwd: how the current directory is shown. Width-aware.
#   - cols >= 100: full ~-collapsed path (~/obsidian/projects/foo)
#   - cols <  100: vault-relative — drops ~/obsidian/ prefix (projects/foo)
#                  Vault root collapses to ~/obs.
#   - any width:   if still longer than $cap, left-truncate with ellipsis.
# Note: \~ is escaped because bash 5 does tilde expansion on the replacement
# of ${var/pat/repl} even inside double quotes.
# ──────────────────────────────────────────────────────────────────────
display_cwd_for() {
  local cwd="$1" max_cols="$2" cap="$3" out
  out="${cwd/#$HOME/\~}"
  if (( max_cols < 100 )); then
    case "$out" in
      "~/obsidian")    out="~/obs" ;;
      "~/obsidian/"*)  out="${out#\~/obsidian/}" ;;
    esac
  fi
  if (( ${#out} > cap )); then
    out="…${out: -$((cap - 1))}"
  fi
  printf '%s' "$out"
}

# Estimate visible width of non-cwd segments so cwd gets the actual remaining
# budget (rather than a naive cols/2). Numbers are upper-bound character widths.
_overhead=19  # baseline: " · 42% · 5:30pm 18%" (ctx + 5h with reset time)
(( show_branch )) && _overhead=$(( _overhead + 12 ))  # " · ⌥ branch"
(( show_model ))  && _overhead=$(( _overhead + 12 ))  # " · Opus 4.7"
(( show_diff ))   && _overhead=$(( _overhead + 10 ))  # " +12 -3"
(( show_bars ))   && _overhead=$(( _overhead + 22 ))  # extra for two bars + labels
(( show_style ))  && _overhead=$(( _overhead + 12 ))  # " · learning"
(( show_agents )) && _overhead=$(( _overhead + 14 ))  # " · ◆ N agent-name"
_cwd_cap=$(( cols - _overhead ))
(( _cwd_cap < 12 )) && _cwd_cap=12
display_cwd="$(display_cwd_for "$cwd" "$cols" "$_cwd_cap")"

# Git: branch + diff stats. The +/- counts already imply dirty, so no `*` marker.
branch=""
git_adds=""
git_dels=""
if [[ -n "${cwd:-}" ]] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
  # Cap long branch names so they don't overflow narrow (phone) widths.
  (( ${#branch} > 20 )) && branch="${branch:0:20}…"
  _shortstat="$(git -C "$cwd" diff --shortstat HEAD 2>/dev/null)"
  if [[ -n "$_shortstat" ]]; then
    _adds="$(printf '%s' "$_shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')"
    _dels="$(printf '%s' "$_shortstat" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+')"
    [[ -n "$_adds" ]] && git_adds="$_adds"
    [[ -n "$_dels" ]] && git_dels="$_dels"
  fi
fi

# Context %
ctx_pct=""
if [[ -n "${ctx_pct_raw:-}" ]]; then
  ctx_pct="$(printf '%.0f%%' "$ctx_pct_raw" 2>/dev/null)"
fi

# Compose. Segments gated by tier flags above; cwd, ctx %, and 5h % always shown.
out=""
[[ -n "$display_cwd" ]] && out="$display_cwd"

if (( show_branch )) && [[ -n "$branch" ]]; then
  out+="$(sep)⌥ $branch"
  if (( show_diff )); then
    [[ -n "$git_adds" ]] && out+=" $(printf '\033[32m+%s\033[0m' "$git_adds")"
    [[ -n "$git_dels" ]] && out+=" $(printf '\033[31m-%s\033[0m' "$git_dels")"
  fi
fi

if (( show_model )) && [[ -n "$model" ]]; then
  out+="$(sep)$(dim "$model")"
fi

if [[ -n "${ctx_pct_raw:-}" ]]; then
  c="$(threshold_color "$ctx_pct_raw")"
  if (( show_bars )); then
    out+="$(sep)$(dim "ctx ")$(ansi "$c" "$(bar "$ctx_pct_raw") $ctx_pct")"
  else
    out+="$(sep)$(ansi "$c" "$ctx_pct")"
  fi
fi

if [[ -n "${five_h_pct:-}" ]]; then
  c="$(threshold_color "$five_h_pct" 75 90)"
  if (( show_bars )); then
    out+="$(sep)$(dim "$five_h_label ")$(ansi "$c" "$(bar "$five_h_pct") $(printf '%.0f' "$five_h_pct")%")"
  else
    # Narrow widths: dim label (reset time when known, else "5h") then percent
    out+="$(sep)$(dim "$five_h_label ")$(ansi "$c" "$(printf '%.0f' "$five_h_pct")%")"
  fi
fi

if (( show_agents )) && [[ -n "${active_agents:-}" ]]; then
  out+="$(sep)$(ansi 36 "◆ $active_agents")"
  [[ -n "$agent_names" ]] && out+="$(dim " $agent_names")"
fi

if (( show_style )) && [[ -n "$style" && "$style" != "default" ]]; then
  out+="$(sep)$(dim "$style")"
fi

printf '%s' "$out"
