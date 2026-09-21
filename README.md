# claudeclip

Pick a [Claude Code](https://claude.com/claude-code) session from your terminal, export it to
Markdown, and copy it straight to your clipboard — no digging through
`~/.claude/projects/*.jsonl` by hand.

```
$ claudeclip
Resume session> fix login redirect loop
> fix login redirect loop        12 minutes ago · main · 84K
  refactor export pipeline       3 hours ago · feat/export · 210K
  add retry to webhook sender    2 days ago · main · 41K
  ...
Export size: 18234 bytes
Copied with xclip
Clipboard size: 18234 bytes
/home/you/.claude/projects/-home-you-myproject/a1b2c3d4-....jsonl -> clipboard and /tmp/claude-conversation-export.md
```

Paste the result into an issue, a PR description, a doc, or another chat —
it's just Markdown with `### User` / `### Assistant` sections.

## Why

Claude Code sessions are stored as JSONL with tool calls, thinking blocks,
and other machinery mixed in with the conversation. `claudeclip` extracts
just the human-readable text, turns it into clean Markdown, and puts it on
the clipboard in one command.

## Features

- **Fuzzy session picker** (via `fzf`) with a live preview of each
  conversation, titled, aged ("3 hours ago"), and tagged with its git branch.
- **Plain numbered fallback** when `fzf` isn't installed — no hard dependency.
- **Smart project lookup**: matches Claude Code's directory-encoding scheme,
  falling back to scanning session `cwd` fields if the encoding ever changes.
- **Noise-free export**: skips empty/tool-only turns and untitled sessions.
- **Optional subagent context**: if the session launched subagents (the
  `Agent` tool), you can pull in their full prompt/response transcript as
  its own `## Subagent: ...` section — not just the "agent launched" notice.
  Off by default (keeps exports small); press `ctrl-r` in the `fzf` picker
  (instead of `enter`) to include *all* of them, or `ctrl-s` to open a second
  picker and choose *which* subagents to include (each with its own preview).
  The numbered fallback asks a `y`/`N` prompt instead (all-or-nothing, since
  there's no picker to choose individually without `fzf`). Progress prints
  as each subagent transcript is pulled in. Skipped gracefully if a
  subagent's transcript file is no longer on disk (it lives under `/tmp`).
- **Safe to paste into another chat**: known trigger-shaped text — slash-command
  invocation blocks (`<command-message>`/`<command-name>`/`<command-args>`),
  `<task-notification>` blocks, `<system-reminder>` tags, and "Background
  command ... completed (exit code N)" notices — gets neutralized in the
  export (angle brackets escaped, or an invisible character inserted) so
  pasting the export into a *different* Claude Code chat can't make it react
  as if those were live signals from its own session. Applies everywhere:
  main transcript and subagent sections alike.
- **Non-interactive mode** for scripts and headless hosts: `--session` skips
  the picker, `--output` picks the file, and neither touches the clipboard.
- **One-shot re-copy** via `claudeclip_copy` if your clipboard got clobbered.

## Requirements

- `bash`
- [`jq`](https://jqlang.org/) — required, used to parse session JSONL
- [`fzf`](https://github.com/junegunn/fzf) — optional, enables the fuzzy
  picker with preview; without it you get a numbered list prompt
- `xclip` — optional, enables copying to the X11 clipboard; without it the
  export is still written to `/tmp/claude-conversation-export.md`

## Install

```bash
git clone git@github.com:DimaTiunov/claudeclip.git ~/opensource/claudeclip
echo '[ -f "$HOME/opensource/claudeclip/claudeclip.sh" ] && source "$HOME/opensource/claudeclip/claudeclip.sh"' >> ~/.bashrc
source ~/.bashrc
```

(Swap `~/.bashrc` for `~/.zshrc` if you're on zsh — the script only uses
POSIX-ish bash constructs and works fine sourced from either.)

## Usage

### Export a session from the current project

```bash
cd ~/code/myproject
claudeclip
```

Opens the `fzf` picker scoped to `myproject`'s Claude Code sessions, sorted
newest first. Pick one, and it's exported to
`/tmp/claude-conversation-export.md` and copied to your clipboard.

In the picker: `enter` exports the conversation as-is, `ctrl-r` also pulls
in every subagent transcript, and `ctrl-s` opens a second picker listing
just that session's subagents (with its own preview per agent) so you can
select — via `tab` — only the ones you actually want.

### Export a session from another project

```bash
claudeclip ~/code/some-other-project
```

### Export without the picker (scripts, cron, headless hosts)

```bash
claudeclip --session "nightly-2026-08-11" --output data/nightly-logs/2026-08-11.md
```

- `--session <id-or-title-substring>` skips the picker. An exact session ID
  wins; otherwise the value is matched (case-insensitively) against session
  titles, among the same sessions the picker would list. Zero matches or more
  than one is an error (exit code 1, candidates listed on stderr), so it is
  safe to run unattended.
- `--output <path>` writes the Markdown to `<path>` instead of
  `/tmp/claude-conversation-export.md`. The directory must already exist.
- Giving either flag skips the `xclip` copy. They combine with a project
  directory as usual: `claudeclip --session foo ~/code/other-project`.
- Subagent transcripts are not included in this mode.
- Missing/empty flag values and unknown options exit with code 2.

`--output` on its own still opens the picker; it only redirects the file.
`claudeclip_copy` keeps working off the default path, so it won't see files
written with `--output`.

### Re-copy the last export

If you overwrote your clipboard after running `claudeclip`:

```bash
claudeclip_copy
```

### Example output

```markdown
# Claude Conversation Export

Source: /home/you/.claude/projects/-home-you-myproject/a1b2c3d4-....jsonl
Title: fix login redirect loop
Exported: 2026-08-04T10:15:32+00:00


### User

Why does /login redirect back to /login after a successful auth?

### Assistant

Looking at your middleware, the session cookie is set after the redirect
response is written...
```

## How it works

1. Resolves the given (or current) directory to Claude Code's project
   folder under `~/.claude/projects/`, using the same character-encoding
   scheme Claude Code itself uses (any non-alphanumeric character becomes
   `-`). If that lookup fails, it falls back to scanning every project's
   session files for a matching `cwd`.
2. Lists that project's `*.jsonl` session files, newest first, filtering out
   sessions with no real text content or no derivable title.
3. Lets you pick one via `fzf` (with a live Markdown preview) or a plain
   numbered prompt.
4. Extracts `user`/`assistant` turns with `jq`, joining multi-part message
   content into Markdown, and writes it to
   `/tmp/claude-conversation-export.md`.
5. Copies the result to the clipboard with `xclip`, if available.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the pull request policy before
proposing a new feature.

## License

[MIT](LICENSE)
