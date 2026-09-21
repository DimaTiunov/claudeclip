# claudeclip — export a Claude Code session (JSONL) to Markdown and copy it
# to the clipboard.
#
# Usage: source this file from ~/.bashrc:
#   [ -f "$HOME/opensource/claudeclip/claudeclip.sh" ] && source "$HOME/opensource/claudeclip/claudeclip.sh"
#
# Provides:
#   claudeclip [dir]  - pick a session (fzf) from the given/current project dir, export + copy
#   claudeclip [--session <id-or-title-substring>] [--output <path>] [dir]
#                     - non-interactive: --session skips the picker, --output
#                       writes to <path>; either one also skips the clipboard
#   claudeclip_copy   - re-copy the last export (/tmp/claude-conversation-export.md)

claudeclip() {
  local root proj out selected selected_file abs_root include_subagents subagent_filter
  local session_given session_query no_clipboard title f
  local -a matches
  root=""
  out="/tmp/claude-conversation-export.md"
  include_subagents=0
  subagent_filter=""
  session_given=0
  session_query=""
  no_clipboard=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session|--output)
        # Checked here rather than defaulting to empty: an unset variable in
        # a wrapper script ("--session $ID") must fail loudly, not silently
        # fall through to the interactive picker on an unattended host.
        [ "$#" -ge 2 ] && [ -n "$2" ] || {
          echo "claudeclip: $1 needs a value" >&2
          return 2
        }
        if [ "$1" = "--session" ]; then
          session_given=1
          session_query="$2"
        else
          out="$2"
        fi
        no_clipboard=1
        shift 2
        ;;
      -*)
        echo "claudeclip: unknown option: $1" >&2
        return 2
        ;;
      *)
        [ -n "$root" ] || root="$1"
        shift
        ;;
    esac
  done

  [ -n "$root" ] || root="$(pwd)"

  [ -d "$(dirname -- "$out")" ] || {
    echo "claudeclip: output directory does not exist: $(dirname -- "$out")" >&2
    return 1
  }

  abs_root="$(realpath "$root")"
  # Claude Code encodes the project path by turning every character that is
  # NOT [A-Za-z0-9] into '-' (so '/', '_', '.', spaces, etc. all become '-').
  # Replacing only '/' (the old sed) breaks for any path containing '_' or
  # '.', e.g. "Desktop/summery_31" -> "-Desktop-summery-31", not "summery_31".
  proj="$HOME/.claude/projects/$(printf '%s' "$abs_root" | sed 's/[^A-Za-z0-9]/-/g')"

  if [ ! -d "$proj" ]; then
    # Fallback: scan every project's session files for one whose recorded
    # "cwd" matches this directory exactly. Keeps claudeclip working even if
    # Claude Code's own encoding scheme ever changes again.
    local needle="\"cwd\":\"${abs_root}\"" f match=""
    for f in "$HOME"/.claude/projects/*/*.jsonl; do
      [ -e "$f" ] || continue
      if grep -F -q -m1 -- "$needle" "$f" 2>/dev/null; then
        match="$(dirname -- "$f")"
        break
      fi
    done
    [ -n "$match" ] && proj="$match"
  fi

  [ -d "$proj" ] || {
    echo "No Claude project dir found: $proj"
    return 1
  }

  _claudeclip_has_text() {
    jq -s -e '
      def text_content:
        if (.message.content | type) == "array" then
          [.message.content[]? | select(.type=="text") | .text] | join("\n")
        else
          (.message.content // "")
        end;

      any(.[]; (.type=="user" or .type=="assistant")
        and (.message.content? != null)
        and ((text_content | gsub("\\s+"; "") | length) > 0)
      )
    ' "$1" >/dev/null 2>&1
  }

  _claudeclip_age() {
    local ts now diff
    ts="$1"
    now="$(date +%s)"
    diff=$((now - ts))

    if [ "$diff" -lt 3600 ]; then
      echo "$((diff / 60)) minutes ago"
    elif [ "$diff" -lt 86400 ]; then
      echo "$((diff / 3600)) hours ago"
    elif [ "$diff" -lt 604800 ]; then
      echo "$((diff / 86400)) days ago"
    else
      echo "$((diff / 604800)) weeks ago"
    fi
  }

  _claudeclip_title() {
    jq -s -r '
      def text_content:
        if (.message.content | type) == "array" then
          [.message.content[]? | select(.type=="text") | .text] | join("\n")
        else
          (.message.content // "")
        end;

      (
        [.[] | select(.type=="ai-title") | .aiTitle?]
        | map(select(. != null and . != ""))
        | .[-1]
      )
      //
      (
        [.[] |
          select(.type=="user")
          | select(.origin.kind? == "human" or .parentUuid == null)
          | select(.message.content? != null)
          | text_content
          | split("\n")
          | map(select(gsub("\\s+"; "") | length > 0))
          | .[0]?
        ]
        | map(select(. != null and . != ""))
        | .[0]
      )
      //
      (
        [.[] | select(.type=="last-prompt") | .lastPrompt?]
        | map(select(. != null and . != ""))
        | .[0]
      )
      //
      "Untitled session"
    ' "$1" 2>/dev/null \
      | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' \
      | cut -c1-90
  }

  _claudeclip_branch() {
    jq -s -r '
      [.[] | .gitBranch?]
      | map(select(. != null and . != ""))
      | .[-1] // "HEAD"
    ' "$1" 2>/dev/null
  }

  _claudeclip_row() {
    local file ts size title branch age
    file="$1"

    _claudeclip_has_text "$file" || return 0

    title="$(_claudeclip_title "$file")"
    [ "$title" != "Untitled session" ] || return 0

    ts="$(stat -c %Y "$file")"
    size="$(du -h "$file" | awk "{print \$1}")"
    branch="$(_claudeclip_branch "$file")"
    age="$(_claudeclip_age "$ts")"

    printf "%s\t%s\t%s · %s · %s\n" "$file" "$title" "$age" "$branch" "$size"
  }

  # $1 = session file. $2 = optional "only include these" filter file, one
  # outputFile path per line (as produced by the ctrl-s subagent picker);
  # omit it to include every subagent found in the session (ctrl-r).
  _claudeclip_subagent_context() {
    local session_file="$1" filter_file="$2" rows agent_id desc output_file
    local found=0 missing=0 total idx=0

    # outputFile/agentId/description live on the tool-result entry for the
    # "Agent" tool call, in the *main* session file — the subagent's own
    # turns live in a separate JSONL under /tmp that may since be gone.
    rows="$(
      jq -s -r '
        .[]
        | select(.toolUseResult.outputFile? != null and .toolUseResult.canReadOutputFile == true)
        | [
            (.toolUseResult.agentId // "?"),
            (.toolUseResult.description // "Subagent" | gsub("[\\t\\n\\r]"; " ")),
            .toolUseResult.outputFile
          ]
        | @tsv
      ' "$session_file" 2>/dev/null
    )"

    if [ -n "$filter_file" ]; then
      rows="$(
        printf '%s\n' "$rows" | while IFS=$'\t' read -r agent_id desc output_file; do
          [ -n "$output_file" ] || continue
          grep -Fxq "$output_file" "$filter_file" 2>/dev/null \
            && printf '%s\t%s\t%s\n' "$agent_id" "$desc" "$output_file"
        done
      )"
    fi

    [ -n "$rows" ] || return 0
    total="$(printf '%s\n' "$rows" | grep -c .)"
    echo "Exporting $total subagent transcript(s)..." >&2

    while IFS=$'\t' read -r agent_id desc output_file; do
      [ -n "$output_file" ] || continue
      idx=$((idx + 1))

      if [ -r "$output_file" ]; then
        found=$((found + 1))
        echo "  [$idx/$total] $desc" >&2
        printf '\n\n---\n\n## Subagent: %s (`%s`)\n' "$desc" "$agent_id"
        jq -s -r '
          def text_content:
            if (.message.content | type) == "array" then
              [.message.content[]? | select(.type=="text") | .text] | join("\n")
            else
              (.message.content // "")
            end;

          .[]
          | select(.type=="user" or .type=="assistant")
          | text_content as $text
          | select($text | gsub("\\s+"; "") | length > 0)
          | "\n\n### " + (
              if .type == "user" then "User"
              elif .type == "assistant" then "Assistant"
              else .type
              end
            ) + "\n\n" + $text
        ' "$output_file"
      else
        missing=$((missing + 1))
      fi
    done <<< "$rows"

    if [ "$missing" -gt 0 ]; then
      echo "($missing subagent transcript(s) no longer on disk, skipped)" >&2
    fi
    if [ "$found" -gt 0 ]; then
      echo "Included $found subagent transcript(s)" >&2
    fi
  }

  _claudeclip_subagent_row_count() {
    jq -s -r '
      [.[] | select(.toolUseResult.outputFile? != null and .toolUseResult.canReadOutputFile == true)]
      | length
    ' "$1" 2>/dev/null
  }

  if [ "$session_given" = "1" ]; then
    matches=()

    # An exact session ID wins outright. Anything else is a case-insensitive
    # substring match on the derived title, restricted to the same sessions
    # the picker would list, so what --session can hit is what you could
    # have clicked on.
    case "$session_query" in
      */*) ;;
      *)
        if [ -f "$proj/$session_query.jsonl" ]; then
          matches=("$proj/$session_query.jsonl")
        fi
        ;;
    esac

    if [ "${#matches[@]}" -eq 0 ]; then
      while IFS= read -r f; do
        _claudeclip_has_text "$f" || continue
        title="$(_claudeclip_title "$f")"
        [ "$title" != "Untitled session" ] || continue
        printf '%s' "$title" | grep -F -i -q -- "$session_query" && matches+=("$f")
      done < <(find "$proj" -maxdepth 1 -name "*.jsonl" -type f | sort)
    fi

    if [ "${#matches[@]}" -eq 0 ]; then
      echo "claudeclip: no session matching '$session_query' in $proj" >&2
      return 1
    elif [ "${#matches[@]}" -gt 1 ]; then
      echo "claudeclip: '$session_query' matches ${#matches[@]} sessions, be more specific:" >&2
      for f in "${matches[@]}"; do
        printf '  %s  %s\n' "$(basename -- "$f" .jsonl)" "$(_claudeclip_title "$f")" >&2
      done
      return 1
    fi

    selected_file="${matches[0]}"
  elif command -v fzf >/dev/null; then
    local subagent_picker_script selection_file key

    # ctrl-s hands off to a *nested* fzf run (fzf's `execute(...)` action
    # suspends the outer picker and gives the nested command the terminal,
    # exactly like a subshell would) that lists just this session's
    # subagents and lets you multi-select which ones to include, instead of
    # all-or-nothing. It's a standalone POSIX sh script rather than inline
    # in --bind because embedding a whole second fzf invocation's quoting
    # inside the outer one's --bind string is unreadable, and this way it
    # doesn't depend on the user's $SHELL being bash (fzf always runs
    # --bind/--preview commands via `$SHELL -c`).
    subagent_picker_script="$(mktemp)"
    cat > "$subagent_picker_script" <<'PICKER_SH'
#!/bin/sh
file="$1"
selection_file="$2"

rows="$(
  jq -s -r '
    .[]
    | select(.toolUseResult.outputFile? != null and .toolUseResult.canReadOutputFile == true)
    | [
        (.toolUseResult.agentId // "?"),
        (.toolUseResult.description // "Subagent" | gsub("[\t\n\r]"; " ")),
        .toolUseResult.outputFile
      ]
    | @tsv
  ' "$file" 2>/dev/null
)"

: > "$selection_file"

if [ -z "$rows" ]; then
  echo "No subagents in this session."
  printf 'Press enter to go back... '
  read -r _ignored </dev/tty
  exit 0
fi

picked="$(
  printf '%s\n' "$rows" | fzf \
    --multi \
    --delimiter="$(printf '\t')" \
    --with-nth=2,1 \
    --height=90% \
    --layout=reverse \
    --prompt='Select subagents (tab to toggle, enter to confirm)> ' \
    --preview '
      out={3}
      if [ -r "$out" ]; then
        jq -s -r "
          def text_content:
            if (.message.content | type) == \"array\" then
              [.message.content[]? | select(.type==\"text\") | .text] | join(\"\n\")
            else
              (.message.content // \"\")
            end;

          .[]
          | select(.type==\"user\" or .type==\"assistant\")
          | text_content as \$text
          | select(\$text | gsub(\"\\\\s+\"; \"\") | length > 0)
          | \"### \" + (
              if .type == \"user\" then \"User\"
              elif .type == \"assistant\" then \"Assistant\"
              else .type
              end
            ) + \"\n\" + (\$text | .[0:1800]) + \"\n\"
        " "$out" 2>/dev/null | head -180
      else
        echo "(transcript no longer on disk)"
      fi
    '
)"

printf '%s\n' "$picked" | cut -f3 > "$selection_file"
PICKER_SH

    selection_file="$(mktemp)"

    selected="$(
      find "$proj" -maxdepth 1 -name "*.jsonl" -type f -printf "%T@ %p\n" \
        | sort -nr \
        | awk '{ $1=""; sub(/^ /,""); print }' \
        | while IFS= read -r file; do _claudeclip_row "$file"; done \
        | fzf \
            --height=90% \
            --layout=reverse \
            --prompt="Resume session> " \
            --delimiter='\t' \
            --with-nth=2,3 \
            --expect=ctrl-r \
            --header='enter: export  ·  ctrl-r: export + all subagents  ·  ctrl-s: choose which subagents' \
            --preview '
              file={1}
              echo "File: $file"
              echo
              jq -s -r "
                def text_content:
                  if (.message.content | type) == \"array\" then
                    [.message.content[]? | select(.type==\"text\") | .text] | join(\"\n\")
                  else
                    (.message.content // \"\")
                  end;

                .[]
                | select(.type==\"user\" or .type==\"assistant\")
                | text_content as \$text
                | select(\$text | gsub(\"\\\\s+\"; \"\") | length > 0)
                | \"### \" + (
                    if .type == \"user\" then \"User\"
                    elif .type == \"assistant\" then \"Assistant\"
                    else .type
                    end
                  ) + \"\n\" + (\$text | .[0:1800]) + \"\n\"
              " "$file" 2>/dev/null | head -180
              count=$(jq -s -r "[.[] | select(.toolUseResult.outputFile? != null and .toolUseResult.canReadOutputFile == true)] | length" "$file" 2>/dev/null)
              if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
                echo
                echo "($count subagent transcript(s) -- ctrl-s to choose, ctrl-r for all)"
              fi
            ' \
            --bind "ctrl-s:execute(sh '$subagent_picker_script' {1} '$selection_file')+accept"
    )"

    key="$(printf '%s' "$selected" | sed -n '1p')"
    selected_file="$(printf "%s" "$selected" | sed -n '2p' | cut -f1)"

    # ctrl-s isn't in --expect: it's not needed there since its own
    # execute(...)+accept binding already ends in an accept, and having a
    # key in both --expect and --bind means --expect's own default accept
    # wins the race and the bound action (our nested picker) never runs.
    # A non-empty selection_file is proof enough that ctrl-s's picker ran.
    if [ -s "$selection_file" ]; then
      include_subagents=1
      # Kept (not removed below) — _claudeclip_subagent_context reads this
      # file later, near the end of this function, and cleans it up itself.
      subagent_filter="$selection_file"
    else
      [ "$key" = "ctrl-r" ] && include_subagents=1
      rm -f "$selection_file"
    fi

    rm -f "$subagent_picker_script"
  else
    local files file i choice subagent_answer
    mapfile -t files < <(
      find "$proj" -maxdepth 1 -name "*.jsonl" -type f -printf "%T@ %p\n" \
        | sort -nr \
        | awk '{ $1=""; sub(/^ /,""); print }' \
        | while IFS= read -r file; do
            if _claudeclip_has_text "$file" && [ "$(_claudeclip_title "$file")" != "Untitled session" ]; then
              echo "$file"
            fi
          done
    )

    [ "${#files[@]}" -gt 0 ] || {
      echo "No non-empty Claude sessions found in: $proj"
      return 1
    }

    echo "Resume session (1 of ${#files[@]})"
    echo

    for i in "${!files[@]}"; do
      file="${files[$i]}"
      printf "%2d) %s\n    %s · %s · %s\n\n" \
        "$((i + 1))" \
        "$(_claudeclip_title "$file")" \
        "$(_claudeclip_age "$(stat -c %Y "$file")")" \
        "$(_claudeclip_branch "$file")" \
        "$(du -h "$file" | awk "{print \$1}")"
    done

    printf "Choose session number: "
    read -r choice

    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    selected_file="${files[$((choice - 1))]}"

    printf "Include subagent transcripts in export? [y/N]: "
    read -r subagent_answer
    case "$subagent_answer" in
      [Yy]*) include_subagents=1 ;;
    esac
  fi

  [ -n "$selected_file" ] && [ -f "$selected_file" ] || {
    echo "No conversation selected"
    return 1
  }

  echo "Exporting session..." >&2

  {
    echo "# Claude Conversation Export"
    echo
    echo "Source: $selected_file"
    echo "Title: $(_claudeclip_title "$selected_file")"
    echo "Exported: $(date -Is)"
    echo

    jq -s -r '
      def text_content:
        if (.message.content | type) == "array" then
          [.message.content[]? | select(.type=="text") | .text] | join("\n")
        else
          (.message.content // "")
        end;

      .[]
      | select(.type=="user" or .type=="assistant")
      | text_content as $text
      | select($text | gsub("\\s+"; "") | length > 0)
      | "\n\n### " + (
          if .type == "user" then "User"
          elif .type == "assistant" then "Assistant"
          else .type
          end
        ) + "\n\n" + $text
    ' "$selected_file"
  } > "$out" || {
    echo "claudeclip: export failed: $selected_file" >&2
    return 1
  }

  if [ "$include_subagents" = "1" ]; then
    _claudeclip_subagent_context "$selected_file" "$subagent_filter" >> "$out"
  elif [ "$session_given" != "1" ]; then
    local available
    available="$(_claudeclip_subagent_row_count "$selected_file")"
    if [ -n "$available" ] && [ "$available" -gt 0 ] 2>/dev/null; then
      echo "($available subagent transcript(s) available, not included -- ctrl-r/ctrl-s in fzf, or answer \"y\" in the fallback prompt)" >&2
    fi
  fi
  [ -n "$subagent_filter" ] && rm -f "$subagent_filter"

  echo "Export size: $(wc -c < "$out") bytes"

  # --session/--output mean a script is driving this: there may be no X11 (or
  # nobody to paste for), and the clipboard is a global side effect.
  if [ "$no_clipboard" = "1" ]; then
    echo "$selected_file -> $out"
    return 0
  fi

  if command -v xclip >/dev/null && [ -n "$DISPLAY" ]; then
    echo "Copying to clipboard..." >&2
    xclip -selection clipboard -i < "$out"
    echo "Copied with xclip"
    echo "Clipboard size: $(xclip -selection clipboard -o 2>/dev/null | wc -c) bytes"
  else
    echo "Saved to $out, but xclip is unavailable"
    echo "DISPLAY=$DISPLAY"
    return 0
  fi

  echo "$selected_file -> clipboard and $out"
}

claudeclip_copy() {
  local out="/tmp/claude-conversation-export.md"

  [ -s "$out" ] || {
    echo "Export file is empty or missing: $out"
    return 1
  }

  echo "Export size: $(wc -c < "$out") bytes"

  if command -v xclip >/dev/null && [ -n "$DISPLAY" ]; then
    xclip -selection clipboard -i < "$out"
    echo "Copied with xclip"
    echo "Clipboard size: $(xclip -selection clipboard -o 2>/dev/null | wc -c) bytes"
  else
    echo "xclip unavailable"
    echo "DISPLAY=$DISPLAY"
    return 1
  fi
}
