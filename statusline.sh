#!/usr/bin/env bash
# Minimal Claude Code statusline. Renders: cwd · branch · model · ctx%
# Input: Claude Code session JSON on stdin.

set -u

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

# Threshold color for usage bars: green <75, yellow 75-89, red >=90
threshold_color() {
  local n
  n=$(printf '%.0f' "${1:-0}")
  if   (( n >= 90 )); then printf '31'
  elif (( n >= 75 )); then printf '33'
  else                     printf '32'
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

# Fields
cwd="$(printf '%s' "$input"       | jq -r '.workspace.current_dir // .cwd // ""')"
model="$(printf '%s' "$input"     | jq -r '.model.display_name // .model.id // ""')"
style="$(printf '%s' "$input"     | jq -r '.output_style.name // ""')"
ctx_pct_raw="$(printf '%s' "$input"   | jq -r '.context_window.used_percentage // empty')"
five_h_pct="$(printf '%s' "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty')"
five_h_resets="$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')"

# Format reset epoch to local "5:30pm" / "9am" (drops :00 on the hour)
fmt_reset_time() {
  local epoch="$1" out
  out=$(date -r "$epoch" '+%-I:%M%p' 2>/dev/null) || return 1
  out="${out//:00/}"
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}
five_h_label="5h"
if [[ -n "${five_h_resets:-}" ]]; then
  t="$(fmt_reset_time "$five_h_resets" 2>/dev/null)" && [[ -n "$t" ]] && five_h_label="$t"
fi

# Active subagents: a*.output symlinks whose target .jsonl was modified
# in the last 60 seconds. The tasks dir lives at
#   /private/tmp/claude-$UID/<project-slug>/<session-uuid>/tasks/
# Project slug = cwd with /, ., space, ~ all replaced by -.
# Agent name is resolved from the parent transcript's toolUseResult.agentType
# and cached at ~/.claude/.statusline-agents.tsv (agent_ids are unique per spawn).
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
  sess_root="/private/tmp/claude-$(id -u)/$slug"
  if [[ -d "$sess_root" ]]; then
    latest_session="$(/bin/ls -t "$sess_root" 2>/dev/null | head -1)"
    tasks_dir="$sess_root/$latest_session/tasks"
    if [[ -d "$tasks_dir" ]]; then
      # Collect active agent types (one per line), tolerate bash 3.2.
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
        # Dedupe with counts, format: "type1, type2×3"
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

# Display cwd: full tilde-collapsed path. Canonicalize iCloud Obsidian
# vault to ~/Obsidian (same data, two filesystem views).
display_cwd="$cwd"
icloud_obsidian="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
if [[ "$display_cwd" == "$icloud_obsidian"* ]]; then
  display_cwd="$HOME/Obsidian${display_cwd#$icloud_obsidian}"
fi
display_cwd="${display_cwd/#$HOME/~}"

# Git: branch + diff stats. The +/- counts already imply dirty, so no `*` marker.
branch=""
git_adds=""
git_dels=""
if [[ -n "${cwd:-}" ]] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
  # Capture line additions/deletions vs HEAD (working tree + index combined)
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
  # Round to integer (Claude Code sends a number, possibly fractional)
  ctx_pct="$(printf '%.0f%%' "$ctx_pct_raw" 2>/dev/null)"
fi

# Compose
out=""
[[ -n "$display_cwd" ]] && out="$display_cwd"
if [[ -n "$branch" ]]; then
  out+="$(sep)⌥ $branch"
  [[ -n "$git_adds" ]] && out+=" $(printf '\033[32m+%s\033[0m' "$git_adds")"
  [[ -n "$git_dels" ]] && out+=" $(printf '\033[31m-%s\033[0m' "$git_dels")"
fi
if [[ -n "$model" ]]; then
  out+="$(sep)$(dim "$model")"
fi
if [[ -n "${ctx_pct_raw:-}" ]]; then
  c="$(threshold_color "$ctx_pct_raw")"
  out+="$(sep)$(dim "ctx ")$(ansi "$c" "$(bar "$ctx_pct_raw") $ctx_pct")"
fi
if [[ -n "${five_h_pct:-}" ]]; then
  c="$(threshold_color "$five_h_pct")"
  out+="$(sep)$(dim "$five_h_label ")$(ansi "$c" "$(bar "$five_h_pct") $(printf '%.0f' "$five_h_pct")%")"
fi
if [[ -n "${active_agents:-}" ]]; then
  # Cyan ◆ for agent indicator; names dim to keep the count prominent
  out+="$(sep)$(ansi 36 "◆ $active_agents")"
  [[ -n "$agent_names" ]] && out+="$(dim " $agent_names")"
fi
if [[ -n "$style" && "$style" != "default" ]]; then
  out+="$(sep)$(dim "$style")"
fi

printf '%s' "$out"
