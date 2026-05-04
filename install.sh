#!/usr/bin/env bash
# Install the Claude Code statusline. Detects OS, copies the right script
# to ~/.claude/statusline.sh, and wires it up in ~/.claude/settings.json.
#
# Usage:
#   ./install.sh           # interactive (prompts before overwriting)
#   ./install.sh --force   # non-interactive (overwrites without asking)
#
# When run by Claude Code (no TTY), the script aborts with a clear message
# if an existing statusline is found and --force was not passed — so CC can
# ask the user before retrying.

set -euo pipefail

force=0
for arg in "$@"; do
  case "$arg" in
    -f|--force|-y|--yes) force=1 ;;
    -h|--help)
      cat <<EOF
Install the Claude Code statusline.

Usage:
  $0           interactive (prompts if existing statusline is found)
  $0 --force   overwrite without asking

Effects:
  - Copies the appropriate script (macOS or Linux) to ~/.claude/statusline.sh
  - Sets .statusLine.command in ~/.claude/settings.json (preserves other keys)
  - Backs up any existing statusline.sh to statusline.sh.backup-<timestamp>

Requires: jq, git (already installed in any environment running Claude Code)
EOF
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="$HOME/.claude"
target_script="$target_dir/statusline.sh"
settings_file="$target_dir/settings.json"

# Pick the script for this OS.
case "$(uname -s)" in
  Darwin) source_script="$repo_dir/statusline.sh" ;;
  Linux)  source_script="$repo_dir/statusline-linux.sh" ;;
  *)
    echo "error: unsupported OS '$(uname -s)'. Only macOS and Linux are supported." >&2
    exit 1
    ;;
esac

if [[ ! -f "$source_script" ]]; then
  echo "error: $source_script not found. Run install.sh from the repo root." >&2
  exit 1
fi

# Hard requirement: jq for JSON parsing in the statusline itself.
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed." >&2
  echo "  macOS: brew install jq" >&2
  echo "  Debian/Ubuntu: sudo apt install jq" >&2
  echo "  RHEL/Fedora: sudo dnf install jq" >&2
  exit 1
fi

mkdir -p "$target_dir"

# Handle existing statusline. The user-chosen policy is: ask before overwriting,
# unless --force is passed. Without a TTY (e.g. invoked by Claude Code), we can't
# prompt — so we abort with a clear message instead of silently overwriting.
if [[ -f "$target_script" ]]; then
  if cmp -s "$source_script" "$target_script"; then
    echo "statusline.sh is already up to date — nothing to do."
    # Still wire it up in settings.json below in case that step was skipped.
  elif (( force )); then
    backup="$target_script.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$target_script" "$backup"
    echo "backed up existing statusline → $backup"
    cp "$source_script" "$target_script"
    echo "installed new statusline → $target_script"
  elif [[ -t 0 ]]; then
    echo "An existing statusline already lives at $target_script."
    echo "It differs from the version about to be installed."
    read -r -p "Overwrite? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES)
        backup="$target_script.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$target_script" "$backup"
        echo "backed up existing statusline → $backup"
        cp "$source_script" "$target_script"
        echo "installed new statusline → $target_script"
        ;;
      *)
        echo "aborted — existing statusline left in place."
        exit 0
        ;;
    esac
  else
    cat >&2 <<EOF
error: an existing statusline already lives at $target_script and differs
from the version about to be installed. No TTY is attached, so this script
cannot prompt for confirmation.

Re-run with --force to overwrite (the existing file will be backed up to
statusline.sh.backup-<timestamp>):

    $0 --force
EOF
    exit 1
  fi
else
  cp "$source_script" "$target_script"
  echo "installed statusline → $target_script"
fi

chmod +x "$target_script"

# Wire up settings.json. Use jq so we don't clobber existing keys (permissions,
# hooks, env, etc). Write to a temp file then mv for atomicity.
desired_command="~/.claude/statusline.sh"
tmp="$settings_file.tmp.$$"
trap 'rm -f "$tmp"' EXIT

if [[ -f "$settings_file" ]]; then
  if ! jq empty "$settings_file" 2>/dev/null; then
    echo "error: $settings_file is not valid JSON. Fix it and re-run." >&2
    exit 1
  fi
  jq --arg cmd "$desired_command" \
     '.statusLine = {type: "command", command: $cmd}' \
     "$settings_file" > "$tmp"
else
  jq -n --arg cmd "$desired_command" \
     '{statusLine: {type: "command", command: $cmd}}' \
     > "$tmp"
fi

mv "$tmp" "$settings_file"
trap - EXIT

echo "wired statusLine in $settings_file"
echo
echo "✓ Installed. Open a new Claude Code session to see the new statusline."
