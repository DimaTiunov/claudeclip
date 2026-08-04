# Contributing

`claudeclip` is a small, single-file shell utility. The bar for merging is
"does it stay simple and not break on someone else's machine" — keep that in
mind for any change.

## Before opening a PR

- **Discuss non-trivial features first.** Open an issue describing the
  problem you're solving and your proposed approach before writing code.
  This avoids wasted work on features that don't fit the tool's scope
  (a session picker + Markdown exporter — not a general Claude Code client).
- **Keep the dependency footprint small.** `jq` is the only hard dependency.
  `fzf` and `xclip` must stay optional, with the script falling back
  gracefully when either is missing. New features may not introduce a new
  hard dependency without discussion.
- **One feature per PR.** Don't bundle an unrelated fix or refactor with a
  new feature — it slows down review and makes `git bisect` useless.

## PR requirements

1. **Description**: what the PR does and why, plus the exact commands you
   ran to test it (this project has no automated test suite — a shown
   terminal transcript is the test).
2. **Manual test evidence**: for any change to `claudeclip()` or
   `claudeclip_copy()`, paste terminal output showing it working, covering:
   - the `fzf` path (if `fzf` is installed)
   - the numbered-prompt fallback (if you can, test with `fzf` uninstalled
     or shadowed, e.g. `PATH=/usr/bin claudeclip`)
   - behavior when `xclip`/`$DISPLAY` is unavailable
3. **Shell compatibility**: code must run under `bash` (the shebang-less
   script is `source`d, so no `#!/bin/bash` assumptions). Avoid bashisms
   that break under `set -u` in a user's existing shell config — the script
   is sourced into their interactive shell, not run in a subshell, so it
   must not leak variables/functions with generic names or call `exit`.
4. **No breaking changes to the public interface** (`claudeclip [dir]`,
   `claudeclip_copy`) without a clear justification in the PR description —
   people have this sourced from their dotfiles.
5. **Keep `jq` filters readable.** Prefer a named `def` over a deeply nested
   one-liner, consistent with the existing `text_content` helper.

## Style

- Local variables: `local` at the top of each function, not inline.
- Prefix internal helper functions with `_claudeclip_` (see
  `_claudeclip_title`, `_claudeclip_age`, etc.) so they don't collide with
  the user's shell environment.
- Quote every variable expansion unless you have a specific reason not to.
- Comments explain *why*, not *what* — see the existing comments on the
  path-encoding logic for the tone to match.

## Review & merge

- PRs are reviewed for correctness, scope, and adherence to the above before
  merge — expect requests for a test transcript if one wasn't included.
- Squash-merge is preferred to keep `main` history readable, one commit per
  feature.
