# claudeclip — export a Claude Code session (JSONL) to Markdown and copy it
# to the clipboard.
#
# Usage: source this file from ~/.bashrc:
#   [ -f "$HOME/opensource/claudeclip/claudeclip.sh" ] && source "$HOME/opensource/claudeclip/claudeclip.sh"
#
# Provides:
#   claudeclip [dir]  - pick a session (fzf) from the given/current project dir, export + copy
#   claudeclip_copy   - re-copy the last export (/tmp/claude-conversation-export.md)

claudeclip() {
  local root proj out selected selected_file abs_root include_subagents
  root="${1:-$(pwd)}"
  out="/tmp/claude-conversation-export.md"
  include_subagents=0

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

  _claudeclip_subagent_context() {
    local session_file="$1" agent_id desc output_file found=0 missing=0

    while IFS=$'\t' read -r agent_id desc output_file; do
      [ -n "$output_file" ] || continue

      if [ -r "$output_file" ]; then
        found=$((found + 1))
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
    done < <(
      # outputFile/agentId/description live on the tool-result entry for the
      # "Agent" tool call, in the *main* session file — the subagent's own
      # turns live in a separate JSONL under /tmp that may since be gone.
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
    )

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

  if command -v fzf >/dev/null; then
    local preview_mode_file preview_script key

    # fzf's preview needs to switch between two very different jq pipelines
    # (plain vs. plus-subagents) on a keypress. Generating a standalone POSIX
    # sh script and invoking it (`sh "$preview_script" {1} "$mode_file"`) is
    # far more readable than trying to nest that much quoting inside a
    # single --preview string, and it works regardless of the user's $SHELL
    # (fzf runs --preview/--bind commands with `$SHELL -c`, and exported
    # bash functions aren't visible there if $SHELL is e.g. zsh).
    preview_mode_file="$(mktemp)"
    printf 'plain' > "$preview_mode_file"

    preview_script="$(mktemp)"
    cat > "$preview_script" <<'PREVIEW_SH'
#!/bin/sh
file="$1"
mode_file="$2"

echo "File: $file"
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
  | "### " + (
      if .type == "user" then "User"
      elif .type == "assistant" then "Assistant"
      else .type
      end
    ) + "\n" + ($text | .[0:1800]) + "\n"
' "$file" 2>/dev/null | head -180

subagents="$(
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

[ -n "$subagents" ] || exit 0

if [ "$(cat "$mode_file" 2>/dev/null)" = "rich" ]; then
  echo
  echo "--- Subagents (ctrl-s to hide) ---"
  printf '%s\n' "$subagents" | while IFS="$(printf '\t')" read -r agent_id desc output_file; do
    [ -r "$output_file" ] || continue
    echo
    echo "## $desc ($agent_id)"
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
      | "### " + (
          if .type == "user" then "User"
          elif .type == "assistant" then "Assistant"
          else .type
          end
        ) + "\n" + ($text | .[0:800]) + "\n"
    ' "$output_file" 2>/dev/null
  done | head -160
else
  count="$(printf '%s\n' "$subagents" | grep -c .)"
  echo
  echo "($count subagent transcript(s) available -- ctrl-s to preview)"
fi
PREVIEW_SH

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
            --header='enter: export  ·  ctrl-r: export + subagents  ·  ctrl-s: toggle subagent preview' \
            --bind "ctrl-s:execute-silent([ \"\$(cat \"$preview_mode_file\")\" = plain ] && printf rich > \"$preview_mode_file\" || printf plain > \"$preview_mode_file\")+refresh-preview" \
            --preview "sh '$preview_script' {1} '$preview_mode_file'"
    )"

    rm -f "$preview_mode_file" "$preview_script"

    key="$(printf '%s' "$selected" | sed -n '1p')"
    [ "$key" = "ctrl-r" ] && include_subagents=1

    selected_file="$(printf "%s" "$selected" | sed -n '2p' | cut -f1)"
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
  } > "$out"

  if [ "$include_subagents" = "1" ]; then
    _claudeclip_subagent_context "$selected_file" >> "$out"
  else
    local available
    available="$(_claudeclip_subagent_row_count "$selected_file")"
    if [ -n "$available" ] && [ "$available" -gt 0 ] 2>/dev/null; then
      echo "($available subagent transcript(s) available, not included -- ctrl-r in fzf, or answer \"y\" in the fallback prompt)" >&2
    fi
  fi

  echo "Export size: $(wc -c < "$out") bytes"

  if command -v xclip >/dev/null && [ -n "$DISPLAY" ]; then
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
