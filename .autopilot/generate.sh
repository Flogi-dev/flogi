#!/usr/bin/env bash
# =============================================================================
# generate.sh — repo-autopilot Step 2: LLM-based Justfile Generator
#
# scan-result.json을 OpenRouter API에 전달하여 justfile을 생성한다.
#
# Usage: bash .autopilot/generate.sh <scan-result.json>
# Output: justfile 내용을 stdout으로 출력
#
# 환경변수 (우선순위: 환경변수 > config.yml > 기본값):
#   OPENROUTER_API_KEY       (필수) OpenRouter API 키
#   AUTOPILOT_MODEL          LLM 모델 (기본: qwen/qwen3-coder-next)
#   AUTOPILOT_FALLBACK_MODEL 폴백 모델 (기본: google/gemini-flash-1.5)
#   AUTOPILOT_MAX_TOKENS     최대 토큰 (기본: 4096)
#   AUTOPILOT_TEMPERATURE    온도 (기본: 0.1)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_FILE="${1:-}"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
PROMPT_FILE="${SCRIPT_DIR}/prompt-template.md"

# --- 입력 검증 ---
if [[ -z "$SCAN_FILE" ]]; then
  echo "❌ Usage: bash generate.sh <scan-result.json>" >&2
  exit 1
fi

if [[ ! -f "$SCAN_FILE" ]]; then
  echo "❌ File not found: $SCAN_FILE" >&2
  exit 1
fi

# .env 자동 로드
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  local_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
  if [[ -f "$local_env" ]]; then
    set -a; source "$local_env"; set +a
  fi
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "❌ OPENROUTER_API_KEY 환경변수가 설정되지 않았습니다." >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "❌ Prompt template not found: $PROMPT_FILE" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ jq가 설치되어 있지 않습니다." >&2
  exit 1
fi

# --- 설정 읽기 (우선순위: 환경변수 > config.yml > 기본값) ---
# 1) 기본값
_DEFAULT_MODEL="qwen/qwen3-coder-next"
_DEFAULT_FALLBACK="google/gemini-flash-1.5"
_DEFAULT_TOKENS="4096"
_DEFAULT_TEMP="0.1"

# 2) config.yml (로컬 개발용, yq 있을 때만)
_CFG_MODEL="$_DEFAULT_MODEL"
_CFG_FALLBACK="$_DEFAULT_FALLBACK"
_CFG_TOKENS="$_DEFAULT_TOKENS"
_CFG_TEMP="$_DEFAULT_TEMP"

if command -v yq &>/dev/null && [[ -f "$CONFIG_FILE" ]]; then
  _CFG_MODEL=$(yq -r '.llm.model // empty' "$CONFIG_FILE" 2>/dev/null)
  _CFG_FALLBACK=$(yq -r '.llm.fallback_model // empty' "$CONFIG_FILE" 2>/dev/null)
  _CFG_TOKENS=$(yq -r '.llm.max_tokens // empty' "$CONFIG_FILE" 2>/dev/null)
  _CFG_TEMP=$(yq -r '.llm.temperature // empty' "$CONFIG_FILE" 2>/dev/null)
  _CFG_MODEL="${_CFG_MODEL:-$_DEFAULT_MODEL}"
  _CFG_FALLBACK="${_CFG_FALLBACK:-$_DEFAULT_FALLBACK}"
  _CFG_TOKENS="${_CFG_TOKENS:-$_DEFAULT_TOKENS}"
  _CFG_TEMP="${_CFG_TEMP:-$_DEFAULT_TEMP}"
fi

# 3) 환경변수가 최우선 (GitHub Variables → workflow env로 주입됨)
MODEL="${AUTOPILOT_MODEL:-$_CFG_MODEL}"
FALLBACK_MODEL="${AUTOPILOT_FALLBACK_MODEL:-$_CFG_FALLBACK}"
MAX_TOKENS="${AUTOPILOT_MAX_TOKENS:-$_CFG_TOKENS}"
TEMPERATURE="${AUTOPILOT_TEMPERATURE:-$_CFG_TEMP}"

echo "📌 Config: model=$MODEL, fallback=$FALLBACK_MODEL, tokens=$MAX_TOKENS, temp=$TEMPERATURE" >&2

# --- 프롬프트 구성 ---
SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
USER_PROMPT=$(cat "$SCAN_FILE")

SYSTEM_PROMPT_ESCAPED=$(echo "$SYSTEM_PROMPT" | jq -Rs '.')
USER_PROMPT_ESCAPED=$(echo "$USER_PROMPT" | jq -Rs '.')

# --- API 호출 함수 ---
call_llm() {
  local model="$1"
  local response

  response=$(curl -s --max-time 120 \
    "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/repo-autopilot" \
    -H "X-Title: repo-autopilot" \
    -d "{
      \"model\": \"$model\",
      \"messages\": [
        {\"role\": \"system\", \"content\": $SYSTEM_PROMPT_ESCAPED},
        {\"role\": \"user\", \"content\": $USER_PROMPT_ESCAPED}
      ],
      \"max_tokens\": $MAX_TOKENS,
      \"temperature\": $TEMPERATURE
    }")

  # 에러 체크
  local error
  error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    echo "⚠️  API error ($model): $error" >&2
    return 1
  fi

  # 응답 추출
  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  if [[ -z "$content" ]]; then
    echo "⚠️  Empty response from $model" >&2
    return 1
  fi

  # 마크다운 코드블록 제거 (LLM이 감쌀 수 있음)
  echo "$content" | sed '/^```\(just\|justfile\|bash\|makefile\)\?$/d' | sed '/^```$/d'
}

# --- 메인: 기본 모델 → fallback ---
echo "🔍 Generating justfile with $MODEL ..." >&2

if justfile_content=$(call_llm "$MODEL"); then
  echo "$justfile_content"
  echo "✅ Generated with $MODEL" >&2
else
  echo "⚠️  Primary model failed. Trying fallback: $FALLBACK_MODEL ..." >&2
  if justfile_content=$(call_llm "$FALLBACK_MODEL"); then
    echo "$justfile_content"
    echo "✅ Generated with fallback: $FALLBACK_MODEL" >&2
  else
    echo "❌ Both models failed. Check API key and network." >&2
    exit 1
  fi
fi
