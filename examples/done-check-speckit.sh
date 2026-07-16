#!/usr/bin/env bash
# Exemplo: driver AFK até zerar checkboxes do Spec Kit.
# Rode a partir da raiz do repo Spec Kit (onde existe tasks.md ou FEATURE_DIR).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Ajuste FEATURE_DIR se tasks.md não estiver na raiz:
TASKS="${TASKS:-tasks.md}"
PROMPT_FILE="${PROMPT_FILE:-$ROOT/prompts/grind-canonical.md}"

# Extrai só o bloco de prompt (entre ```text e ```)
PROMPT="$(awk '/^```text$/{p=1;next}/^```$/{if(p){exit}}p' "$PROMPT_FILE")"

export STUCK_LOG="${STUCK_LOG:-.specify/agentic-loop.log}"
export STUCK_LIMIT="${STUCK_LIMIT:-2}"
export DONE_CHECK="! grep -qE '^[[:space:]]*-[[:space:]]*\[ \]' \"$TASKS\""
export MAX_ITERS="${MAX_ITERS:-50}"

# Opcional: reservar limite humano de manhã
# export AVAILABLE_BY="10:00"
# export AVAILABLE_MIN=70

exec "$ROOT/claude-loop.sh" "$PROMPT"
