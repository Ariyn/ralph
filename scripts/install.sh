#!/usr/bin/env bash

set -euo pipefail

DEFAULT_OWNER="Ariyn"
DEFAULT_REPO="ralph"
DEFAULT_REF="main"

OWNER="${RALPH_REPO_OWNER:-$DEFAULT_OWNER}"
REPO="${RALPH_REPO_NAME:-$DEFAULT_REPO}"
REF="${RALPH_REF:-$DEFAULT_REF}"
TARGET_DIR="${RALPH_TARGET_DIR:-scripts/ralph}"
CODEX_SKILLS_DIR="${RALPH_CODEX_SKILLS_DIR:-.agents/skills}"
SOURCE_DIR="${RALPH_SOURCE_DIR:-}"
FORCE=0

usage() {
  cat <<'EOF_USAGE'
Ralph을 현재 프로젝트에 설치합니다.

사용법:
  curl -fsSL https://raw.githubusercontent.com/$\{DEFAULT_OWNER\}/$\{DEFAULT_REPO\}/$\{DEFAULT_REF\}/scripts/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/$\{DEFAULT_OWNER\}/$\{DEFAULT_REPO\}/$\{DEFAULT_REF\}/scripts/install.sh | bash -s -- --dir tooling/ralph
  curl -fsSL https://raw.githubusercontent.com/$\{DEFAULT_OWNER\}/$\{DEFAULT_REPO\}/$\{DEFAULT_REF\}/scripts/install.sh | bash -s -- --codex-skills-dir .agents/skills

옵션:
  --dir, --target-dir PATH  설치 경로를 현재 디렉터리 기준으로 지정 (기본값: scripts/ralph)
  --codex-skills-dir PATH   Codex skills 설치 경로 (기본값: .agents/skills, 상대/절대 경로 가능)
  --owner NAME              원격 설치를 위한 GitHub owner 지정 (기본값: ${DEFAULT_OWNER})
  --repo NAME               원격 설치를 위한 GitHub repo 지정 (기본값: ${DEFAULT_REPO})
  --ref REF                 원격 설치를 위한 Git ref 지정 (기본값: ${DEFAULT_REF})
  --force                   관리되는 파일이 이미 존재해도 강제로 덮어씀
  --help                    이 도움말 표시

환경 변수:
  RALPH_SOURCE_DIR          파일을 다운로드하는 대신 복사해올 로컬 Ralph 경로
  RALPH_TARGET_DIR          기본 설치 경로 오버라이드
  RALPH_CODEX_SKILLS_DIR    Codex skills 설치 경로 오버라이드
  RALPH_REPO_OWNER          기본 GitHub owner 오버라이드
  RALPH_REPO_NAME           기본 GitHub repo 오버라이드
  RALPH_REF                 기본 Git ref 오버라이드
EOF_USAGE
}

log() {
  printf "[ralph-install] %s\n" "$1"
}

warn() {
  printf "[ralph-install] Warning: %s\n" "$1" >&2
}

fail() {
  printf "[ralph-install] Error: %s\n" "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|--target-dir)
      [[ $# -ge 2 ]] || fail "$1 옵션의 값이 누락되었습니다."
      TARGET_DIR="$2"
      shift 2
      ;;
    --codex-skills-dir)
      [[ $# -ge 2 ]] || fail "$1 옵션의 값이 누락되었습니다."
      CODEX_SKILLS_DIR="$2"
      shift 2
      ;;
    --owner)
      [[ $# -ge 2 ]] || fail "$1 옵션의 값이 누락되었습니다."
      OWNER="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || fail "$1 옵션의 값이 누락되었습니다."
      REPO="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || fail "$1 옵션의 값이 누락되었습니다."
      REF="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "알 수 없는 옵션: $1"
      ;;
  esac
done

TARGET_DIR="${TARGET_DIR#./}"
TARGET_DIR="${TARGET_DIR%/}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR%/}"

[[ -n "$TARGET_DIR" ]] || fail "대상 디렉터리는 비어있을 수 없습니다."
[[ "$TARGET_DIR" != /* ]] || fail "대상 디렉터리는 현재 디렉터리 기준의 상대 경로여야 합니다."
[[ -n "$CODEX_SKILLS_DIR" ]] || fail "Codex skills 디렉터리는 비어있을 수 없습니다."

if [[ -z "$SOURCE_DIR" ]] && ! command -v curl >/dev/null 2>&1; then
  fail "원격 설치를 위해 curl이 필요합니다."
fi

PROJECT_ROOT="$PWD"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
INSTALL_DIR="$PROJECT_ROOT/$TARGET_DIR"
RAW_BASE_URL="${RALPH_RAW_BASE_URL:-https://raw.githubusercontent.com/$OWNER/$REPO/$REF}"

if [[ "$CODEX_SKILLS_DIR" = /* ]]; then
  CODEX_SKILLS_INSTALL_DIR="$CODEX_SKILLS_DIR"
else
  CODEX_SKILLS_INSTALL_DIR="$PROJECT_ROOT/$CODEX_SKILLS_DIR"
fi

if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  if [[ "$GIT_ROOT" != "$PROJECT_ROOT" ]]; then
    warn "현재 디렉터리가 git 루트가 아닙니다. $PROJECT_ROOT 에 설치를 계속합니다."
  fi
else
  warn "git 저장소가 감지되지 않았습니다. Ralph은 git 프로젝트 내부에서 가장 잘 작동합니다."
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/plans" "$INSTALL_DIR/skills/prd" "$INSTALL_DIR/skills/ralph" "$CODEX_SKILLS_INSTALL_DIR/prd" "$CODEX_SKILLS_INSTALL_DIR/ralph"

CHECKSUM_MANIFEST="$INSTALL_DIR/.ralph-install-checksums"
CHECKSUM_MANIFEST_WORK="$(mktemp)"
if [[ -f "$CHECKSUM_MANIFEST" ]]; then
  cp "$CHECKSUM_MANIFEST" "$CHECKSUM_MANIFEST_WORK"
fi

cleanup() {
  rm -f "$CHECKSUM_MANIFEST_WORK"
}
trap cleanup EXIT

slugify() {
  printf "%s" "$1" | tr "[:upper:]" "[:lower:]" | sed -E "s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//"
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf "%s" "$value"
}

PROJECT_SLUG="$(slugify "$PROJECT_NAME")"
if [[ -z "$PROJECT_SLUG" ]]; then
  PROJECT_SLUG="project"
fi

BOOTSTRAP_BRANCH="ralph/bootstrap-$PROJECT_SLUG"

relative_path() {
  local path="$1"
  printf "%s\n" "${path#"$PROJECT_ROOT"/}"
}

sha256_file() {
  local file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file_path" | awk '{print $NF}'
    return
  fi

  fail "체크섬 계산을 위해 sha256sum, shasum, openssl 중 하나가 필요합니다."
}

manifest_key() {
  local file_path="$1"
  if [[ "$file_path" == "$PROJECT_ROOT"/* ]]; then
    printf "%s\n" "${file_path#"$PROJECT_ROOT"/}"
  else
    printf "%s\n" "$file_path"
  fi
}

manifest_get() {
  local key="$1"
  awk -F $'\t' -v k="$key" '$1 == k { print $2; exit }' "$CHECKSUM_MANIFEST_WORK"
}

manifest_set() {
  local key="$1"
  local checksum="$2"
  local temp_file

  temp_file="$(mktemp)"
  awk -F $'\t' -v k="$key" '$1 != k { print $0 }' "$CHECKSUM_MANIFEST_WORK" > "$temp_file"
  printf "%s\t%s\n" "$key" "$checksum" >> "$temp_file"
  mv "$temp_file" "$CHECKSUM_MANIFEST_WORK"
}

sync_managed_file_from_local_source() {
  local source_file="$1"
  local destination_path="$2"
  local display_path source_checksum key recorded_checksum current_checksum

  display_path="$(relative_path "$destination_path")"
  source_checksum="$(sha256_file "$source_file")"
  key="$(manifest_key "$destination_path")"

  if [[ -f "$destination_path" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      cp "$source_file" "$destination_path"
      manifest_set "$key" "$source_checksum"
      log "강제 덮어쓰기 완료: $display_path"
      return
    fi

    recorded_checksum="$(manifest_get "$key")"
    current_checksum="$(sha256_file "$destination_path")"

    if [[ -z "$recorded_checksum" ]]; then
      manifest_set "$key" "$current_checksum"
      log "체크섬 기준이 없어 파일 유지(다음 실행부터 추적): $display_path"
      return
    fi

    if [[ "$current_checksum" != "$recorded_checksum" ]]; then
      log "로컬 변경 감지로 파일 유지: $display_path"
      return
    fi

    cp "$source_file" "$destination_path"
    manifest_set "$key" "$source_checksum"
    log "업데이트 완료: $display_path"
    return
  fi

  cp "$source_file" "$destination_path"
  manifest_set "$key" "$source_checksum"
  log "설치 완료: $display_path"
}

download_or_copy() {
  local source_path="$1"
  local destination_path="$2"
  local temp_file

  temp_file="$(mktemp)"

  if [[ -n "$SOURCE_DIR" ]]; then
    local local_source="$SOURCE_DIR/$source_path"
    [[ -f "$local_source" ]] || fail "로컬 소스 파일을 찾을 수 없음: $local_source"
    cp "$local_source" "$temp_file"
  else
    curl -fsSL "$RAW_BASE_URL/$source_path" -o "$temp_file"
  fi

  sync_managed_file_from_local_source "$temp_file" "$destination_path"
  rm -f "$temp_file"
}

ensure_file() {
  local file_path="$1"
  local file_contents="$2"
  local temp_file

  temp_file="$(mktemp)"
  printf "%s" "$file_contents" > "$temp_file"

  sync_managed_file_from_local_source "$temp_file" "$file_path"
  rm -f "$temp_file"
}

ensure_unmanaged_file() {
  local file_path="$1"
  local file_contents="$2"

  if [[ -f "$file_path" && "$FORCE" -ne 1 ]]; then
    log "기존 파일 유지: $(relative_path "$file_path")"
    return
  fi

  printf "%s" "$file_contents" > "$file_path"
  log "초기화 완료: $(relative_path "$file_path")"
}

ensure_gitignore_entry() {
  local gitignore_path="$1"
  local entry="$2"

  touch "$gitignore_path"

  if grep -Fqx "$entry" "$gitignore_path"; then
    return
  fi

  if [[ -s "$gitignore_path" ]] && [[ "$(tail -c 1 "$gitignore_path" | wc -l | tr -d " ")" == "0" ]]; then
    printf "\n" >> "$gitignore_path"
  fi

  printf "%s\n" "$entry" >> "$gitignore_path"
  log ".gitignore 에 $entry 추가 완료"
}

download_or_copy "ralph.sh" "$INSTALL_DIR/ralph.sh"
download_or_copy "PLAN.md" "$INSTALL_DIR/PLAN.md"
download_or_copy "CLAUDE.md" "$INSTALL_DIR/CLAUDE.md"
download_or_copy "CODEX.md" "$INSTALL_DIR/CODEX.md"
download_or_copy "skills/prd/SKILL.md" "$INSTALL_DIR/skills/prd/SKILL.md"
download_or_copy "skills/ralph/SKILL.md" "$INSTALL_DIR/skills/ralph/SKILL.md"
download_or_copy "skills/prd/SKILL.md" "$CODEX_SKILLS_INSTALL_DIR/prd/SKILL.md"
download_or_copy "skills/ralph/SKILL.md" "$CODEX_SKILLS_INSTALL_DIR/ralph/SKILL.md"

chmod +x "$INSTALL_DIR/ralph.sh"

ensure_file "$INSTALL_DIR/prd.json" "{
  \"project\": \"$(json_escape "$PROJECT_NAME")\",
  \"branchName\": \"$(json_escape "$BOOTSTRAP_BRANCH")\",
  \"description\": \"Ralph 초기화 플레이스홀더 - 이 PRD를 실제 기능 계획으로 교체하세요.\",
  \"defaults\": {
    \"verification\": [],
    \"maxRetries\": 2,
    \"scope\": {}
  },
  \"userStories\": [
    {
      \"id\": \"US-000\",
      \"title\": \"Ralph 워크스페이스 초기화\",
      \"description\": \"프로젝트 유지 관리자로서, 향후 스토리들이 유효한 기준점에서 시작할 수 있도록 Ralph 부트스트랩 파일을 준비하고 싶다.\",
      \"acceptanceCriteria\": [
        \"$(json_escape "$TARGET_DIR") 하위에 부트스트랩 파일들이 존재함\",
        \"plans/plan-00.md 에 플레이스홀더 계획이 존재함\",
        \"이 초기화 스토리는 이미 완료로 표시됨\"
      ],
      \"priority\": 0,
      \"plan\": \"plans/plan-00.md\",
      \"status\": \"passed\",
      \"passes\": true,
      \"retryCount\": 0,
      \"blocked\": null,
      \"notes\": \"실제 작업을 위해 Ralph을 실행하기 전에 이 플레이스홀더 PRD를 실제 기능 계획으로 교체하세요.\"
    }
  ]
}
"

ensure_unmanaged_file "$INSTALL_DIR/progress.txt" "# Ralph 진행 로그
시작됨: $(date)
---
"

ensure_file "$INSTALL_DIR/plans/plan-00.md" "# Ralph 초기화 플레이스홀더

- 상태: 완료
- 목적: 이 계획 문서는 설치 직후 생성된 \`prd.json\`이 즉시 유효하도록 존재합니다.

## 다음 단계

1. \`../prd.json\`을 실제 기능 PRD로 교체하세요.
2. 이 파일을 첫 번째 스토리를 위한 실제 계획으로 교체하세요.
3. \`prd.json\`에서 참조하는 추가 스토리들을 위해 \`plan-xx.md\` 파일들을 추가하세요.
"

GITIGNORE_PATH="$PROJECT_ROOT/.gitignore"
ensure_gitignore_entry "$GITIGNORE_PATH" "$TARGET_DIR"
cp "$CHECKSUM_MANIFEST_WORK" "$CHECKSUM_MANIFEST"

cat <<EOF_MSG

Ralph 부트스트랩이 완료되었습니다.

설치 경로: $TARGET_DIR

준비된 파일:
  - $TARGET_DIR/ralph.sh
  - $TARGET_DIR/PLAN.md
  - $TARGET_DIR/CLAUDE.md
  - $TARGET_DIR/CODEX.md
  - $TARGET_DIR/skills/prd/SKILL.md
  - $TARGET_DIR/skills/ralph/SKILL.md
  - $(relative_path "$CODEX_SKILLS_INSTALL_DIR")/prd/SKILL.md
  - $(relative_path "$CODEX_SKILLS_INSTALL_DIR")/ralph/SKILL.md
  - $TARGET_DIR/.ralph-install-checksums
  - $TARGET_DIR/prd.json
  - $TARGET_DIR/progress.txt
  - $TARGET_DIR/plans/plan-00.md

다음 단계:
  1. 준비가 되면 $TARGET_DIR/prd.json 을 실제 기능 PRD로 교체하거나 편집하세요.
  2. $TARGET_DIR/plans/plan-00.md 을 교체하고 실제 스토리들을 위한 plan-xx.md 파일들을 추가하세요.
  3. Claude용 공유 skills는 $TARGET_DIR/skills 하위에 설치됩니다 (전역 사용 시 ~/.claude/skills 로 복사).
  4. Codex용 skills는 $(relative_path "$CODEX_SKILLS_INSTALL_DIR") 하위에 설치됩니다 (Codex 공식 검색 경로).
  5. Codex가 새 스킬을 바로 못 찾으면 Codex를 재시작하세요.
  6. $TARGET_DIR/PLAN.md, $TARGET_DIR/CLAUDE.md, $TARGET_DIR/CODEX.md 를 프로젝트에 맞게 수정하세요.
  7. ./$TARGET_DIR/ralph.sh [--tool codex] [--plan-model ...] [--exec-model ...] 명령으로 실행하세요.

빠른 설치 명령:
  curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/$REF/scripts/install.sh | bash
EOF_MSG
