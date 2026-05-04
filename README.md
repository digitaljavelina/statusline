# Claude Code Statusline

A minimal, information-dense statusline for [Claude Code](https://claude.com/claude-code) that fits on a phone over SSH and scales up to a wide laptop terminal.

```
~/code/statusline · ⌥ main +12 -3 · Opus 4.7 · ctx ███░░░░░ 42% · 5:30pm █░░░░░░░ 18% · ◆ 2 code-reviewer, explore
```

Renders, in order:

- **cwd** — current directory (tilde-collapsed)
- **⌥ branch** — git branch with green `+N` adds and red `-N` deletions vs `HEAD`
- **model** — current Claude model
- **ctx %** — context window usage with an 8-cell bar (green <41 · yellow 41–65 · red ≥66)
- **5h %** — 5-hour rate-limit usage; the label flips to the local reset time (`5:30pm`) when known
- **◆ N** — count of active subagents, with deduped agent-type names
- **output style** — appended only when not `default`

Two variants ship in this repo:

| script                | for   | notes                                                                                                            |
| --------------------- | ----- | ---------------------------------------------------------------------------------------------------------------- |
| `statusline.sh`       | macOS | Bash 3.2 compatible, BSD `date`, `/private/tmp/` paths, iCloud Obsidian → `~/Obsidian` canonicalization          |
| `statusline-linux.sh` | Linux | GNU `date`, `/tmp/` paths, **progressive-disclosure tiers** that adapt to terminal width (phone/iPad/laptop SSH) |

The installer detects your OS and picks the right one.

## Install

### Quick install (one command)

```bash
git clone https://github.com/digitaljavelina/statusline.git && cd statusline && ./install.sh
```

Re-run the same command later to update — it'll prompt before overwriting if it sees a different version.

### Asking Claude Code to install it

Tell Claude Code:

> Install the statusline from https://github.com/digitaljavelina/statusline

Claude Code will clone the repo and run `./install.sh --force` (the `--force` flag is needed because Claude Code has no TTY for the overwrite prompt). Existing statuslines are backed up to `statusline.sh.backup-<timestamp>` before being replaced.

### What `install.sh` does

1. Detects OS (`uname -s`) and picks `statusline.sh` (macOS) or `statusline-linux.sh` (Linux).
2. Verifies `jq` is installed (the statusline parses Claude Code's session JSON with it).
3. Copies the script to `~/.claude/statusline.sh` and `chmod +x`'s it.
   - If a different statusline already exists there, prompts to overwrite (or aborts with a clear message under `--force` for non-interactive use). The existing file is backed up before any overwrite.
4. Updates `~/.claude/settings.json` to wire it up — using `jq` to set just `.statusLine`, preserving any other keys (permissions, hooks, env vars) that are already there.

The resulting `settings.json` snippet:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

### Requirements

- `bash` (3.2+ on macOS, 4+ on Linux)
- `jq` — `brew install jq` / `sudo apt install jq` / `sudo dnf install jq`
- `git` — used for branch + diff detection

### Manual install

If you'd rather not run the installer:

```bash
# macOS
cp statusline.sh ~/.claude/statusline.sh

# Linux
cp statusline-linux.sh ~/.claude/statusline.sh

chmod +x ~/.claude/statusline.sh
```

Then edit `~/.claude/settings.json` and add:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

## How it works

### The data source

Claude Code invokes the statusline command on every render and pipes a JSON session payload to its stdin. The script reads that with a single `cat`, then pulls fields with `jq`:

- `.workspace.current_dir`
- `.model.display_name`
- `.context_window.used_percentage`
- `.rate_limits.five_hour.used_percentage` and `.resets_at`
- `.output_style.name`

Output goes to stdout. ANSI color codes are emitted directly — Claude Code passes them through to your terminal.

### Git branch and diff stats

A single `git diff --shortstat HEAD` returns insertions and deletions in one roundtrip; a two-stage `grep -oE` extracts the numbers (the first stage anchors to the `insertion`/`deletion` keyword so filenames like `file42.txt` can't slip in, the second strips the keyword). Working tree and index are combined — the `+N -N` counts already imply dirty, so there's no separate `*` marker.

### Subagent detection

When Claude Code spawns a subagent, it writes an `agent-<id>.jsonl` transcript and creates an `a*.output` symlink under:

```
/private/tmp/claude-$UID/<project-slug>/<session-uuid>/tasks/   # macOS
/tmp/claude-$UID/<project-slug>/<session-uuid>/tasks/           # Linux
```

The project slug is the cwd with `/`, `.`, space, and `~` all replaced by `-`. The script:

1. Finds `a*.output` symlinks whose targets were modified in the last 60 seconds (`find -L … -newermt '60 seconds ago'`).
2. Reads each symlink's target to discover the agent transcript path.
3. Walks back up to the parent session JSONL at `~/.claude/projects/<slug>/<session>.jsonl`.
4. Greps for the `agentId` and pulls `toolUseResult.agentType` to get a friendly name (e.g. `code-reviewer`).

Resolved names are cached at `~/.claude/.statusline-agents.tsv` (TSV: `agent_id\tagent_type`). Agent IDs are unique per spawn, so the cache never goes stale — it just grows by one row per agent. Cache hit avoids re-parsing the transcript on every render, which is what makes this fast enough to run on every keystroke.

The display dedupes and counts: `code-reviewer, explore×3` for one reviewer plus three explore agents.

### Threshold colors and the progress bar

```bash
threshold_color() {
  local n=$(printf '%.0f' "${1:-0}")
  if   (( n >= 66 )); then printf '31'   # red
  elif (( n >= 41 )); then printf '33'   # yellow
  else                     printf '32'   # green
  fi
}
```

The 8-cell bar is built with `awk` doing the float math (`filled = pct * width / 100`, rounded), then `█` and `░` characters concatenated in a `while` loop. Bash 3.2 doesn't have `printf -v` for repeated chars, so the loop is portable across both macOS and Linux variants.

### Linux variant: progressive disclosure

The Linux script reads the terminal width from `stty size </dev/tty` and gates segments by tier:

| width       | segments shown                                  | typical context                |
| ----------- | ----------------------------------------------- | ------------------------------ |
| **<60**     | cwd, ctx %, 5h %                                | phone portrait (Termius/Blink) |
| **60–99**   | + branch (name only), model                     | phone landscape, iPad portrait |
| **100–119** | + bars, ctx/5h labels, diff stats, output style | iPad landscape, laptop SSH     |
| **≥120**    | + active agent indicator                        | laptop wide                    |

Why `stty size </dev/tty`? `tput cols` defaults to 80 because `$TERM` isn't propagated to the subprocess Claude Code spawns; bash doesn't export `$COLUMNS`. The redirect is wrapped in `{ …; } 2>/dev/null` so it can't leak stderr when no tty exists (e.g. CI).

The cwd is also width-aware: under 100 cols, `~/obsidian/projects/foo` collapses to `projects/foo` (drops the vault prefix); the vault root collapses to `~/obs`. Long paths are left-truncated with `…` so the leaf directory stays visible. The truncation cap isn't a naive `cols/2` — it's `cols - sum_of_other_segment_widths`, so cwd is the segment that gives way first when other fields grow.

### Linux variant: control-byte resilience

Claude Code session JSON occasionally contains raw bytes in U+0000–U+001F inside string values (technically invalid JSON). All `jq` calls have stderr silenced; if the first parse pass returns no fields, a second pass runs against `tr -d`-scrubbed input. That loses whatever was in the rogue string but recovers the rest of the document.

### Linux variant: timezone

Reset time formatting respects the system TZ by default. Override with `STATUSLINE_TZ=America/New_York` if you SSH into a server in a different timezone than the one you live in.

## Environment variable overrides (Linux)

| var                              | effect                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| `STATUSLINE_COLS=52`             | Force a specific tier — useful for testing or to keep compact mode on a wide terminal |
| `STATUSLINE_TZ=America/New_York` | Override system TZ for the 5h reset time                                              |

## Debugging

Trigger a one-shot dump of the session JSON Claude Code is sending:

```bash
touch ~/.claude/.statusline-debug
# next render writes ~/.claude/.statusline-input.json and clears the flag
jq . ~/.claude/.statusline-input.json
```

The flag self-disables on the next render, so you don't end up with a perpetually growing dump file.

If the statusline isn't rendering at all, run the script manually with sample input:

```bash
echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 4.7"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":18}}}' | ~/.claude/statusline.sh
```

## Uninstall

```bash
rm ~/.claude/statusline.sh
# Then edit ~/.claude/settings.json and delete the "statusLine" key.
```

To remove the agent-type cache too: `rm ~/.claude/.statusline-agents.tsv`.

## License

[MIT](LICENSE) — © 2026 Michael Henry.
