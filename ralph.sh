#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool claude|codex] [--plan-model MODEL] [--exec-model MODEL] [--plan-reasoning EFFORT] [--exec-reasoning EFFORT] [max_iterations]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./ralph.sh [options] [max_iterations]

Options:
  --tool TOOL               claude (default) or codex
  --plan-model MODEL        override the planning model for the selected tool
  --exec-model MODEL        override the implementation model for the selected tool
  --plan-reasoning LEVEL    codex only: planning reasoning effort (default: xhigh)
  --exec-reasoning LEVEL    codex only: implementation reasoning effort (default: medium)
  --help                    show this message

Defaults:
  Claude planning model: claude-opus-4-6
  Claude execution model: claude-sonnet-4-6
  Codex planning model: gpt-5.4 with xhigh reasoning
  Codex execution model: gpt-5.4 with medium reasoning
EOF
}

TOOL="${RALPH_TOOL:-claude}"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-10}"
PLAN_MODEL="${RALPH_PLAN_MODEL:-}"
EXEC_MODEL="${RALPH_EXEC_MODEL:-}"
PLAN_REASONING="${RALPH_PLAN_REASONING:-}"
EXEC_REASONING="${RALPH_EXEC_REASONING:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)
      [[ $# -ge 2 ]] || { echo "Error: --tool requires a value."; exit 1; }
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --plan-model)
      [[ $# -ge 2 ]] || { echo "Error: --plan-model requires a value."; exit 1; }
      PLAN_MODEL="$2"
      shift 2
      ;;
    --plan-model=*)
      PLAN_MODEL="${1#*=}"
      shift
      ;;
    --exec-model)
      [[ $# -ge 2 ]] || { echo "Error: --exec-model requires a value."; exit 1; }
      EXEC_MODEL="$2"
      shift 2
      ;;
    --exec-model=*)
      EXEC_MODEL="${1#*=}"
      shift
      ;;
    --plan-reasoning)
      [[ $# -ge 2 ]] || { echo "Error: --plan-reasoning requires a value."; exit 1; }
      PLAN_REASONING="$2"
      shift 2
      ;;
    --plan-reasoning=*)
      PLAN_REASONING="${1#*=}"
      shift
      ;;
    --exec-reasoning)
      [[ $# -ge 2 ]] || { echo "Error: --exec-reasoning requires a value."; exit 1; }
      EXEC_REASONING="$2"
      shift 2
      ;;
    --exec-reasoning=*)
      EXEC_REASONING="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Error: Unknown argument '$1'."
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'claude' or 'codex'."
  exit 1
fi

default_plan_model() {
  case "$1" in
    claude) printf '%s\n' 'claude-opus-4-6' ;;
    codex) printf '%s\n' 'gpt-5.4' ;;
  esac
}

default_exec_model() {
  case "$1" in
    claude) printf '%s\n' 'claude-sonnet-4-6' ;;
    codex) printf '%s\n' 'gpt-5.4' ;;
  esac
}

PLAN_MODEL="${PLAN_MODEL:-$(default_plan_model "$TOOL")}"
EXEC_MODEL="${EXEC_MODEL:-$(default_exec_model "$TOOL")}"

if [[ "$TOOL" == "codex" ]]; then
  PLAN_REASONING="${PLAN_REASONING:-xhigh}"
  EXEC_REASONING="${EXEC_REASONING:-medium}"
else
  PLAN_REASONING=""
  EXEC_REASONING=""
fi

ROOT_DIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
PLAN_PROMPT_FILE="$SCRIPT_DIR/PLAN.md"
CLAUDE_PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
CODEX_PROMPT_FILE="$SCRIPT_DIR/CODEX.md"

[[ -f "$PRD_FILE" ]] || { echo "Error: Missing $PRD_FILE"; exit 1; }
[[ -f "$PROGRESS_FILE" ]] || { echo "# Ralph Progress Log" > "$PROGRESS_FILE"; echo "Started: $(date)" >> "$PROGRESS_FILE"; echo "---" >> "$PROGRESS_FILE"; }
[[ -f "$PLAN_PROMPT_FILE" ]] || { echo "Error: Missing $PLAN_PROMPT_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required."; exit 1; }
command -v "$TOOL" >/dev/null 2>&1 || { echo "Error: '$TOOL' is not installed or not on PATH."; exit 1; }

if [[ -f "$PRD_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [[ -n "$CURRENT_BRANCH" && -n "$LAST_BRANCH" && "$CURRENT_BRANCH" != "$LAST_BRANCH" ]]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
if [[ -n "$CURRENT_BRANCH" ]]; then
  echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
fi

json_field() {
  local json_input="$1"
  local filter="$2"
  printf '%s\n' "$json_input" | jq -r "$filter"
}

get_next_story_json() {
  jq -c '[.userStories | to_entries[] | select((.value.passes // false) != true)] | sort_by(.value.priority // 999999, .key) | .[0].value // empty' "$PRD_FILE"
}

default_plan_path_for_story() {
  local story_id="$1"
  local suffix
  suffix=$(printf '%s' "$story_id" | sed -nE 's/.*-([0-9]+)$/\1/p')

  if [[ -n "$suffix" ]]; then
    printf 'plans/plan-%s.md\n' "$suffix"
  else
    suffix=$(printf '%s' "$story_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    printf 'plans/%s.md\n' "${suffix:-plan-next-story}"
  fi
}

ensure_story_plan_path() {
  local story_id="$1"
  local plan_path="$2"
  local temp_file

  temp_file="$(mktemp)"
  jq --arg story_id "$story_id" --arg plan_path "$plan_path" '(.userStories[] | select(.id == $story_id) | .plan) = $plan_path' "$PRD_FILE" > "$temp_file"
  mv "$temp_file" "$PRD_FILE"
}

resolve_plan_abspath() {
  local plan_path="$1"
  if [[ "$plan_path" = /* ]]; then
    printf '%s\n' "$plan_path"
  else
    printf '%s\n' "$ROOT_DIR/$plan_path"
  fi
}

compose_plan_prompt() {
  local output_file="$1"
  local story_json="$2"
  local plan_rel="$3"
  local story_id story_title story_priority

  story_id=$(json_field "$story_json" '.id')
  story_title=$(json_field "$story_json" '.title')
  story_priority=$(json_field "$story_json" '.priority // ""')

  {
    cat "$PLAN_PROMPT_FILE"
    printf '\n\n---\n\n## Ralph Runtime Context\n\n'
    printf -- '- Mode: plan-only\n'
    printf -- '- Selected story ID: %s\n' "$story_id"
    printf -- '- Selected story title: %s\n' "$story_title"
    printf -- '- Selected story priority: %s\n' "$story_priority"
    printf -- '- Target plan path: %s\n' "$plan_rel"
    printf -- '- Stop immediately after writing the plan file.\n'
    printf '\n### Selected Story JSON\n\n```json\n'
    printf '%s\n' "$story_json" | jq '.'
    printf '```\n'
  } > "$output_file"
}

compose_execution_prompt() {
  local output_file="$1"
  local base_prompt_file="$2"
  local story_json="$3"
  local plan_rel="$4"
  local plan_abs="$5"
  local story_id story_title story_priority

  story_id=$(json_field "$story_json" '.id')
  story_title=$(json_field "$story_json" '.title')
  story_priority=$(json_field "$story_json" '.priority // ""')

  {
    cat "$base_prompt_file"
    printf '\n\n---\n\n## Ralph Runtime Context\n\n'
    printf -- '- Mode: implementation\n'
    printf -- '- Selected story ID: %s\n' "$story_id"
    printf -- '- Selected story title: %s\n' "$story_title"
    printf -- '- Selected story priority: %s\n' "$story_priority"
    printf -- '- Plan path: %s\n' "$plan_rel"
    printf -- '- Implement only this story. Do not switch to another pending story.\n'
    printf -- '- Use the plan below as the primary execution guide.\n'
    printf '\n### Selected Story JSON\n\n```json\n'
    printf '%s\n' "$story_json" | jq '.'
    printf '```\n'
    printf '\n### Current Story Plan (%s)\n\n' "$plan_rel"
    cat "$plan_abs"
    printf '\n'
  } > "$output_file"
}

run_claude() {
  local model="$1"
  local prompt_file="$2"
  local output status

  set +e
  output=$(claude --dangerously-skip-permissions --print --model "$model" < "$prompt_file" 2>&1 | tee /dev/stderr)
  status=$?
  set -e

  printf '%s' "$output"
  return "$status"
}

run_codex() {
  local model="$1"
  local reasoning="$2"
  local prompt_file="$3"
  local output status

  set +e
  output=$(codex exec --full-auto --sandbox workspace-write --model "$model" -c "model_reasoning_effort=\"$reasoning\"" - < "$prompt_file" 2>&1 | tee /dev/stderr)
  status=$?
  set -e

  printf '%s' "$output"
  return "$status"
}

run_agent_capture() {
  local mode="$1"
  local prompt_file="$2"

  AGENT_OUTPUT=""
  AGENT_STATUS=0

  if [[ "$TOOL" == "claude" ]]; then
    local model="$EXEC_MODEL"
    if [[ "$mode" == "plan" ]]; then
      model="$PLAN_MODEL"
    fi

    if AGENT_OUTPUT="$(run_claude "$model" "$prompt_file")"; then
      AGENT_STATUS=0
    else
      AGENT_STATUS=$?
    fi
  else
    local model reasoning

    if [[ "$mode" == "plan" ]]; then
      model="$PLAN_MODEL"
      reasoning="$PLAN_REASONING"
    else
      model="$EXEC_MODEL"
      reasoning="$EXEC_REASONING"
    fi

    if AGENT_OUTPUT="$(run_codex "$model" "$reasoning" "$prompt_file")"; then
      AGENT_STATUS=0
    else
      AGENT_STATUS=$?
    fi
  fi
}

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
echo "Planning model: $PLAN_MODEL${PLAN_REASONING:+ ($PLAN_REASONING reasoning)}"
echo "Execution model: $EXEC_MODEL${EXEC_REASONING:+ ($EXEC_REASONING reasoning)}"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  NEXT_STORY_JSON="$(get_next_story_json)"

  if [[ -z "$NEXT_STORY_JSON" ]]; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed before iteration $i needed any work."
    exit 0
  fi

  STORY_ID="$(json_field "$NEXT_STORY_JSON" '.id')"
  STORY_TITLE="$(json_field "$NEXT_STORY_JSON" '.title')"
  STORY_PLAN_REL="$(json_field "$NEXT_STORY_JSON" '(.plan // "") | gsub("^\\s+|\\s+$"; "")')"
  PLAN_STATUS_REASON=""

  if [[ -z "$STORY_PLAN_REL" ]]; then
    STORY_PLAN_REL="$(default_plan_path_for_story "$STORY_ID")"
    ensure_story_plan_path "$STORY_ID" "$STORY_PLAN_REL"
    echo "Assigned missing plan path for $STORY_ID: $STORY_PLAN_REL"
    PLAN_STATUS_REASON="plan path was missing"
  fi

  STORY_PLAN_ABS="$(resolve_plan_abspath "$STORY_PLAN_REL")"

  if [[ ! -s "$STORY_PLAN_ABS" ]]; then
    if [[ -z "$PLAN_STATUS_REASON" ]]; then
      PLAN_STATUS_REASON="plan file is missing or empty"
    fi

    mkdir -p "$(dirname "$STORY_PLAN_ABS")"

    TEMP_PROMPT_FILE="$(mktemp)"
    compose_plan_prompt "$TEMP_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL"

    echo "Selected story $STORY_ID ($STORY_TITLE) needs planning because $PLAN_STATUS_REASON."
    echo "Generating plan with $TOOL using $PLAN_MODEL${PLAN_REASONING:+ ($PLAN_REASONING reasoning)}..."

    run_agent_capture plan "$TEMP_PROMPT_FILE"
    rm -f "$TEMP_PROMPT_FILE"

    if [[ ! -s "$STORY_PLAN_ABS" ]]; then
      echo "Error: Planning run finished without creating $STORY_PLAN_REL"
      exit 1
    fi

    if [[ "$AGENT_STATUS" -ne 0 ]]; then
      echo "Warning: $TOOL exited with status $AGENT_STATUS after writing the plan."
    fi

    echo "Plan generated at $STORY_PLAN_REL. Exiting before implementation."
    exit 0
  fi

  TEMP_PROMPT_FILE="$(mktemp)"
  if [[ "$TOOL" == "claude" ]]; then
    compose_execution_prompt "$TEMP_PROMPT_FILE" "$CLAUDE_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL" "$STORY_PLAN_ABS"
  else
    compose_execution_prompt "$TEMP_PROMPT_FILE" "$CODEX_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL" "$STORY_PLAN_ABS"
  fi

  echo "Implementing $STORY_ID ($STORY_TITLE) using $TOOL with $EXEC_MODEL${EXEC_REASONING:+ ($EXEC_REASONING reasoning)}..."
  run_agent_capture execute "$TEMP_PROMPT_FILE"
  rm -f "$TEMP_PROMPT_FILE"

  if [[ "$AGENT_STATUS" -ne 0 ]]; then
    echo "Warning: $TOOL exited with status $AGENT_STATUS"
  fi

  if printf '%s' "$AGENT_OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
