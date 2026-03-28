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

is_scope_guard_ignored_file() {
  local file="$1"
  local ignored_file

  while IFS= read -r ignored_file; do
    [[ -n "$ignored_file" ]] || continue
    if [[ "$file" == "$ignored_file" ]]; then
      return 0
    fi
  done < <(get_guard_ignored_files)

  return 1
}

repo_relative_path() {
  local abs_path="$1"

  if [[ "$abs_path" == "$REPO_ROOT" ]]; then
    printf '.\n'
  elif [[ "$abs_path" == "$REPO_ROOT/"* ]]; then
    printf '%s\n' "${abs_path#"$REPO_ROOT"/}"
  else
    return 1
  fi
}

get_guard_ignored_files() {
  repo_relative_path "$PROGRESS_FILE"
  repo_relative_path "$PRD_FILE"
}

guarded_changed_files() {
  local baseline_commit="$1"
  local ignored_file
  local -a diff_args=(--name-only)

  if [[ -n "$baseline_commit" ]]; then
    diff_args+=("$baseline_commit" HEAD)
  else
    diff_args+=(--cached)
  fi

  diff_args+=(-- .)
  while IFS= read -r ignored_file; do
    [[ -n "$ignored_file" ]] || continue
    diff_args+=(":(exclude)$ignored_file")
  done < <(get_guard_ignored_files)

  git diff "${diff_args[@]}" 2>/dev/null || echo ""
}

guarded_added_lines() {
  local baseline_commit="$1"
  local ignored_file
  local -a diff_args=(--numstat)

  if [[ -n "$baseline_commit" ]]; then
    diff_args+=("$baseline_commit" HEAD)
  else
    diff_args+=(--cached)
  fi

  diff_args+=(-- .)
  while IFS= read -r ignored_file; do
    [[ -n "$ignored_file" ]] || continue
    diff_args+=(":(exclude)$ignored_file")
  done < <(get_guard_ignored_files)

  git diff "${diff_args[@]}" 2>/dev/null | awk -F '\t' '{ if ($1 ~ /^[0-9]+$/) s += $1 } END { print s+0 }'
}

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
PLAN_PROMPT_FILE="$SCRIPT_DIR/PLAN.md"
CLAUDE_PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
CODEX_PROMPT_FILE="$SCRIPT_DIR/CODEX.md"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$SCRIPT_DIR")"

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

glob_to_regex() {
  local glob="$1"
  printf '%s' "$glob" \
    | sed -e 's/[.+^${}()|[\]\\]/\\&/g' \
          -e 's/\*\*/.*/g' \
          -e 's/\*/[^\/]*/g' \
          -e 's/?/[^\/]/g'
}

get_next_story_json() {
  jq -c '
    [.userStories | to_entries[] | select(
      ((.value.status // (if (.value.passes // false) then "passed" else "pending" end))
       | . != "passed" and . != "blocked")
    )] | sort_by(.value.priority // 999999, .key) | .[0].value // empty
  ' "$PRD_FILE"
}

set_story_status() {
  local story_id="$1"
  local new_status="$2"
  local retry_count="${3:-}"
  local blocked_reason="${4:-}"
  local weak_validation="${5:-false}"
  local timestamp
  local temp_file

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  temp_file="$(mktemp)"

  jq --arg id "$story_id" --arg status "$new_status" \
     --arg rc "$retry_count" --arg br "$blocked_reason" \
     --arg wv "$weak_validation" \
     --arg ts "$timestamp" '
    (.userStories[] | select(.id == $id)) |= (
      .status = $status |
      if $status == "passed" then .passes = true else . end |
      if $rc != "" then .retryCount = ($rc | tonumber) else . end |
      if $status == "blocked" then .blocked = {reason: $br, failedAt: $ts} else . end |
      if $wv == "true" then .weakValidation = true else . end
    )
  ' "$PRD_FILE" > "$temp_file"
  mv "$temp_file" "$PRD_FILE"
}

get_merged_verification() {
  local story_json="$1"
  local story_verification

  story_verification=$(printf '%s\n' "$story_json" | jq -r '.verification // empty | .[]' 2>/dev/null)

  if [[ -n "$story_verification" ]]; then
    printf '%s\n' "$story_verification"
  else
    jq -r '.defaults.verification // [] | .[]' "$PRD_FILE" 2>/dev/null
  fi
}

get_merged_field() {
  local story_json="$1"
  local field="$2"
  local fallback="$3"
  local val

  val=$(printf '%s\n' "$story_json" | jq -r ".$field // empty" 2>/dev/null)
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
  else
    jq -r ".defaults.$field // $fallback" "$PRD_FILE" 2>/dev/null
  fi
}

run_verification_commands() {
  local story_json="$1"
  local cmd
  local all_passed=true
  local verification_cmds

  verification_cmds="$(get_merged_verification "$story_json")"

  if [[ -z "$verification_cmds" ]]; then
    echo "No verification commands configured. Skipping verification."
    return 0
  fi

  echo "Running verification commands..."
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    echo "  Running: $cmd"
    if eval "$cmd"; then
      echo "  PASSED: $cmd"
    else
      echo "  FAILED: $cmd"
      all_passed=false
    fi
  done <<< "$verification_cmds"

  if $all_passed; then
    return 0
  else
    return 1
  fi
}

run_scope_guards() {
  local story_json="$1"
  local baseline_commit="$2"
  local scope_json changed_files filtered_changed_files="" violations=""

  scope_json=$(printf '%s\n' "$story_json" | jq -c '.scope // empty' 2>/dev/null)
  if [[ -z "$scope_json" ]]; then
    scope_json=$(jq -c '.defaults.scope // empty' "$PRD_FILE" 2>/dev/null)
  fi
  [[ -z "$scope_json" ]] && return 0

  changed_files=$(guarded_changed_files "$baseline_commit")
  [[ -z "$changed_files" ]] && return 0

  local deny_paths
  deny_paths=$(printf '%s' "$scope_json" | jq -r '.denyPaths // [] | .[]' 2>/dev/null)
  if [[ -n "$deny_paths" ]]; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      local regex
      regex="^$(glob_to_regex "$pattern")$"
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if printf '%s\n' "$file" | grep -qE "$regex"; then
          violations+="  DENIED: $file matches denyPath '$pattern'\n"
        fi
      done <<< "$changed_files"
    done <<< "$deny_paths"
  fi

  local allow_paths
  allow_paths=$(printf '%s' "$scope_json" | jq -r '.allowPaths // [] | .[]' 2>/dev/null)
  if [[ -n "$allow_paths" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if is_scope_guard_ignored_file "$file"; then
        continue
      fi
      local matched=false
      while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        local regex
        regex="^$(glob_to_regex "$pattern")$"
        if printf '%s\n' "$file" | grep -qE "$regex"; then
          matched=true
          break
        fi
      done <<< "$allow_paths"
      if ! $matched; then
        violations+="  NOT ALLOWED: $file not in any allowPath\n"
      fi
    done <<< "$changed_files"
  fi

  if [[ -n "$violations" ]]; then
    echo "Scope guard violations:"
    printf '%b' "$violations"
    return 1
  fi
  return 0
}

run_budget_guards() {
  local story_json="$1"
  local baseline_commit="$2"
  local max_files max_lines budget_enforced
  local actual_files actual_lines
  local warned=false

  max_files=$(get_merged_field "$story_json" 'maxChangedFiles' 'null')
  max_lines=$(get_merged_field "$story_json" 'maxAddedLines' 'null')
  [[ "$max_files" == "null" && "$max_lines" == "null" ]] && return 0

  budget_enforced=$(get_merged_field "$story_json" 'budgetEnforced' 'false')

  actual_files=$(guarded_changed_files "$baseline_commit" | wc -l | tr -d ' ')
  actual_lines=$(guarded_added_lines "$baseline_commit")

  if [[ "$max_files" != "null" ]] && [[ "$actual_files" -gt "$max_files" ]]; then
    echo "  Budget: $actual_files files changed (max: $max_files)"
    warned=true
  fi

  if [[ "$max_lines" != "null" ]] && [[ "$actual_lines" -gt "$max_lines" ]]; then
    echo "  Budget: $actual_lines lines added (max: $max_lines)"
    warned=true
  fi

  if $warned; then
    if [[ "$budget_enforced" == "true" ]]; then
      echo "  Budget enforced: FAILED"
      return 1
    else
      echo "  Budget exceeded (warning only, set budgetEnforced: true to enforce)"
    fi
  fi
  return 0
}

run_repo_validation() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local validate_script="$repo_root/.ralph/validate.sh"

  if [[ -x "$validate_script" ]]; then
    echo "Running repository validation: $validate_script"
    if bash "$validate_script"; then
      echo "  PASSED: $validate_script"
      return 0
    else
      echo "  FAILED: $validate_script"
      return 1
    fi
  fi
  return 2
}

init_run_dir() {
  local story_id="$1"
  local run_id
  run_id="$(date +%Y%m%d-%H%M%S)-${story_id}"
  local run_dir="$SCRIPT_DIR/.ralph/runs/$run_id"
  mkdir -p "$run_dir"
  printf '%s\n' "$run_dir"
}

write_result_file() {
  local run_dir="$1"
  local story_id="$2"
  local runner="$3"
  local passed="$4"
  local guards_passed="$5"
  local weak="$6"
  local start_ts="$7"
  local end_ts="$8"

  jq -n \
    --arg taskId "$story_id" \
    --arg runner "$runner" \
    --argjson passed "$passed" \
    --argjson guardsPassed "$guards_passed" \
    --argjson weak "$weak" \
    --arg startedAt "$start_ts" \
    --arg completedAt "$end_ts" \
    '{
      taskId: $taskId,
      validation: {
        runner: $runner,
        passed: $passed,
        guardsPassed: $guardsPassed,
        weakValidation: $weak,
        startedAt: $startedAt,
        completedAt: $completedAt
      }
    }' > "$run_dir/result.json"
}

run_all_validation() {
  local story_json="$1"
  local story_id="$2"
  local run_dir="$3"
  local baseline_commit="$4"
  local validation_runner="none"
  local validation_passed=true
  local guards_passed=true
  local weak_validation=false
  local start_ts end_ts

  start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "Running common guards..."
  if ! run_scope_guards "$story_json" "$baseline_commit"; then
    guards_passed=false
    validation_passed=false
  fi
  if ! run_budget_guards "$story_json" "$baseline_commit"; then
    guards_passed=false
    validation_passed=false
  fi

  local verification_cmds
  verification_cmds="$(get_merged_verification "$story_json")"

  if [[ -n "$verification_cmds" ]]; then
    validation_runner="task_verification"
    if ! run_verification_commands "$story_json"; then
      validation_passed=false
    fi
  else
    run_repo_validation
    local repo_val_status=$?
    if [[ "$repo_val_status" -eq 0 ]]; then
      validation_runner="repo_validate_sh"
    elif [[ "$repo_val_status" -eq 1 ]]; then
      validation_runner="repo_validate_sh"
      validation_passed=false
    else
      validation_runner="guards_only"
      weak_validation=true
      echo "Warning: No verification commands or .ralph/validate.sh found."
      echo "  Only common guards were checked. Marking as weak_validation."
    fi
  fi

  end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  write_result_file "$run_dir" "$story_id" "$validation_runner" \
    "$validation_passed" "$guards_passed" "$weak_validation" \
    "$start_ts" "$end_ts"

  if $validation_passed; then
    return 0
  else
    return 1
  fi
}

all_remaining_blocked() {
  jq '
    [.userStories[] | select(
      (.status // (if (.passes // false) then "passed" else "pending" end))
      | . != "passed"
    )] | length > 0 and all(.status == "blocked")
  ' "$PRD_FILE"
}

get_scope_json() {
  local story_id="$1"
  jq -r --arg id "$story_id" '
    (.userStories[] | select(.id == $id)) as $s |
    ($s.scope // .defaults.scope // {}) | tojson
  ' "$PRD_FILE"
}

get_verification_json() {
  local story_id="$1"
  jq -r --arg id "$story_id" '
    (.userStories[] | select(.id == $id)) as $s |
    ($s.verification // .defaults.verification // []) | tojson
  ' "$PRD_FILE"
}

agent_reported_complete() {
  local agent_output="$1"
  local last_nonempty_line

  last_nonempty_line="$(printf '%s\n' "$agent_output" | awk '{ gsub(/\r/, ""); if (NF) line=$0 } END { print line }')"
  [[ "$last_nonempty_line" == "<promise>COMPLETE</promise>" ]]
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
    printf '%s\n' "$SCRIPT_DIR/$plan_path"
  fi
}

compose_plan_prompt() {
  local output_file="$1"
  local story_json="$2"
  local plan_rel="$3"
  local plan_abs="$4"
  local story_id story_title story_priority

  story_id=$(json_field "$story_json" '.id')
  story_title=$(json_field "$story_json" '.title')
  story_priority=$(json_field "$story_json" '.priority // ""')

  {
    cat "$PLAN_PROMPT_FILE"
    printf '\n\n---\n\n## Ralph Runtime Context\n\n'
    printf -- '- Mode: plan-only\n'
    printf -- '- Ralph control directory: %s\n' "$SCRIPT_DIR"
    printf -- '- PRD path: %s\n' "$PRD_FILE"
    printf -- '- Progress log path: %s\n' "$PROGRESS_FILE"
    printf -- '- Selected story ID: %s\n' "$story_id"
    printf -- '- Selected story title: %s\n' "$story_title"
    printf -- '- Selected story priority: %s\n' "$story_priority"
    printf -- '- Target plan path: %s\n' "$plan_rel"
    printf -- '- Target plan absolute path: %s\n' "$plan_abs"
    printf -- '- Relative plan values in the story JSON are relative to the Ralph control directory above.\n'
    printf -- '- Use these exact paths instead of inferring paths from the temporary prompt file location.\n'
    printf -- '- Stop immediately after writing the plan file.\n'
    printf -- '- Scope constraints: %s\n' "$(get_scope_json "$story_id")"
    printf -- '- Verification commands: %s\n' "$(get_verification_json "$story_id")"
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
    printf -- '- Ralph control directory: %s\n' "$SCRIPT_DIR"
    printf -- '- PRD path: %s\n' "$PRD_FILE"
    printf -- '- Progress log path: %s\n' "$PROGRESS_FILE"
    printf -- '- Selected story ID: %s\n' "$story_id"
    printf -- '- Selected story title: %s\n' "$story_title"
    printf -- '- Selected story priority: %s\n' "$story_priority"
    printf -- '- Plan path: %s\n' "$plan_rel"
    printf -- '- Plan absolute path: %s\n' "$plan_abs"
    printf -- '- Relative plan values in the story JSON are relative to the Ralph control directory above.\n'
    printf -- '- Use these exact paths instead of inferring paths from the temporary prompt file location.\n'
    printf -- '- Implement only this story. Do not switch to another pending story.\n'
    printf -- '- Use the plan below as the primary execution guide.\n'
    printf -- '- Scope constraints: %s\n' "$(get_scope_json "$story_id")"
    printf -- '- Verification commands: %s\n' "$(get_verification_json "$story_id")"
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
    compose_plan_prompt "$TEMP_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL" "$STORY_PLAN_ABS"

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
  fi

  TEMP_PROMPT_FILE="$(mktemp)"
  if [[ "$TOOL" == "claude" ]]; then
    compose_execution_prompt "$TEMP_PROMPT_FILE" "$CLAUDE_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL" "$STORY_PLAN_ABS"
  else
    compose_execution_prompt "$TEMP_PROMPT_FILE" "$CODEX_PROMPT_FILE" "$NEXT_STORY_JSON" "$STORY_PLAN_REL" "$STORY_PLAN_ABS"
  fi

  set_story_status "$STORY_ID" "in_progress"

  BASELINE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo "")"

  echo "Implementing $STORY_ID ($STORY_TITLE) using $TOOL with $EXEC_MODEL${EXEC_REASONING:+ ($EXEC_REASONING reasoning)}..."
  run_agent_capture execute "$TEMP_PROMPT_FILE"
  rm -f "$TEMP_PROMPT_FILE"

  if [[ "$AGENT_STATUS" -ne 0 ]]; then
    echo "Warning: $TOOL exited with status $AGENT_STATUS"
  fi

  # --- Validation & retry logic ---
  MERGED_MAX_RETRIES="$(get_merged_field "$NEXT_STORY_JSON" 'maxRetries' '2')"
  CURRENT_RETRY="$(json_field "$NEXT_STORY_JSON" '.retryCount // 0')"

  RUN_DIR="$(init_run_dir "$STORY_ID")"

  if run_all_validation "$NEXT_STORY_JSON" "$STORY_ID" "$RUN_DIR" "$BASELINE_COMMIT"; then
    echo "Validation passed for $STORY_ID"

    # Check if weak validation
    WEAK_VAL="false"
    if [[ -f "$RUN_DIR/result.json" ]] && \
       [[ "$(jq -r '.validation.weakValidation' "$RUN_DIR/result.json")" == "true" ]]; then
      echo "Warning: Passed with weak validation (no project-specific checks)"
      WEAK_VAL="true"
    fi
    set_story_status "$STORY_ID" "passed" "" "" "$WEAK_VAL"

    # Check requiresApproval
    REQUIRES_APPROVAL="$(json_field "$NEXT_STORY_JSON" '.requiresApproval // false')"
    if [[ "$REQUIRES_APPROVAL" == "true" ]]; then
      echo ""
      echo "Story $STORY_ID requires human approval. Pausing."
      echo "Review the changes, then press Enter to continue or Ctrl-C to abort."
      if [[ -t 0 ]]; then
        read -r
      else
        echo "Non-interactive mode: skipping approval pause."
      fi
    fi
  else
    NEXT_RETRY=$((CURRENT_RETRY + 1))
    if [[ "$NEXT_RETRY" -ge "$MERGED_MAX_RETRIES" ]]; then
      echo "Story $STORY_ID exceeded max retries ($MERGED_MAX_RETRIES). Marking as blocked."
      set_story_status "$STORY_ID" "blocked" "$NEXT_RETRY" "Validation failed after $NEXT_RETRY attempts"
    else
      echo "Validation failed for $STORY_ID (attempt $NEXT_RETRY of $MERGED_MAX_RETRIES). Will retry."
      set_story_status "$STORY_ID" "failed" "$NEXT_RETRY"
    fi
  fi

  # --- Check completion ---
  REMAINING_STORY_JSON="$(get_next_story_json)"

  if [[ -z "$REMAINING_STORY_JSON" ]]; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  # Check if all remaining stories are blocked
  if [[ "$(all_remaining_blocked)" == "true" ]]; then
    echo ""
    echo "All remaining stories are blocked. Ralph cannot proceed."
    echo "Check $PRD_FILE for blocked stories and their reasons."
    exit 1
  fi

  # The PRD is the source of truth. Some agent CLIs or responses can echo the
  # completion token even when there are still pending stories.
  if agent_reported_complete "$AGENT_OUTPUT"; then
    echo "Warning: Ignoring completion token because pending stories still remain in $PRD_FILE"
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
