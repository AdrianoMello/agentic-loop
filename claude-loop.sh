#!/usr/bin/env bash
# claude-loop — roda uma tarefa no Claude Code headless EM LOOP, sobrevivendo ao
# estouro do limite de uso: detecta "You've hit your limit · resets HH:MM", dorme
# ate a hora do reset e retoma de onde parou. Ideal para tarefas longas/AFK
# (build de feature, validacao, refactor iterativo) sem babá.
#
# O estado do trabalho deve viver em DISCO (arquivos, git) — nao na sessao. Assim,
# se o limite matar a invocacao, a proxima retomada le o disco e continua.
#
# Uso:
#   ./claude-loop.sh "seu prompt aqui"
#   PROMPT_FILE=tarefa.md ./claude-loop.sh
#   # roda ate nao haver mais checkbox aberto em tasks.md:
#   DONE_CHECK='! grep -qE "^\s*-\s*\[ \]" tasks.md' ./claude-loop.sh "/implemente a proxima tarefa nao marcada; pare ao concluir uma"
#
# Knobs (variaveis de ambiente):
#   CLAUDE      caminho do CLI claude          (default: claude no PATH)
#   MODEL       modelo                          (default: claude-fable-5)
#   EFFORT      low | medium | high | max       (default: high)
#   MAX_ITERS   teto de iteracoes               (default: 50)
#   DONE_CHECK  comando shell; o loop PARA quando ele retorna 0 (default: roda 1x e sai)
#   PROMPT_FILE arquivo com o prompt (alternativa ao argumento)
#   LOGDIR      pasta p/ log de cada iteracao (default: ./claude-loop-logs, 1 arquivo por iter)
#
# SEGURANCA: usa --dangerously-skip-permissions (autonomo, sem confirmar). Rode
# so em repo/branch que voce controla. NUNCA ponha segredo no prompt/arquivo.
set -uo pipefail

CLAUDE="${CLAUDE:-claude}"
MODEL="${MODEL:-claude-fable-5}"
EFFORT="${EFFORT:-high}"
MAX_ITERS="${MAX_ITERS:-50}"
PROMPT="${1:-}"; [ -z "$PROMPT" ] && [ -n "${PROMPT_FILE:-}" ] && PROMPT="$(cat "$PROMPT_FILE")"
[ -z "$PROMPT" ] && { echo "erro: forneca um prompt (argumento) ou PROMPT_FILE=<arquivo>" >&2; exit 2; }
LOGDIR="${LOGDIR:-./claude-loop-logs}"; mkdir -p "$LOGDIR"
BACKOFF=300; MAX_BACKOFF=3600   # backoff de fallback: 5min -> 1h

run()          { "$CLAUDE" -p --model "$MODEL" --effort "$EFFORT" --dangerously-skip-permissions "$1" 2>&1 | tee "$LOG"; return "${PIPESTATUS[0]}"; }
rate_limited() { grep -qiE "hit your limit|limit reached|reached .*limit|usage limit|rate limit|resets?[[:space:]]+[0-9]|too many requests|overloaded|429" "$LOG"; }
wait_reset()   {
  # dorme ate a hora que o CLI informa ("resets 12:30am"); se nao parsear, backoff cego
  local rt target now
  rt=$(grep -oiE 'resets?[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' "$LOG" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | head -1)
  if [ -n "$rt" ] && target=$(date -d "$rt" +%s 2>/dev/null) && [ -n "$target" ]; then
    now=$(date +%s); [ "$target" -le "$now" ] && target=$((target+86400))
    echo ">> limite atingido; dormindo ate $rt (~$(( (target-now)/60 ))min)" >&2
    sleep $(( target-now+120 ))                  # +2min de folga
  else
    echo ">> limite atingido; dormindo ${BACKOFF}s" >&2
    sleep "$BACKOFF"; BACKOFF=$(( BACKOFF*2>MAX_BACKOFF?MAX_BACKOFF:BACKOFF*2 ))
  fi
}
done_check()   { [ -z "${DONE_CHECK:-}" ] && return 1; eval "$DONE_CHECK"; }

iter=0
while : ; do
  if done_check; then echo ">> DONE_CHECK satisfeito; concluido."; break; fi
  iter=$((iter+1)); [ "$iter" -gt "$MAX_ITERS" ] && { echo ">> teto MAX_ITERS=$MAX_ITERS atingido."; break; }
  LOG="$LOGDIR/iter-$(printf '%03d' "$iter").log"
  echo ">> ===== iteracao $iter (log: $LOG) ====="
  if run "$PROMPT"; then
    BACKOFF=300                                  # sucesso: reseta o backoff
    [ -z "${DONE_CHECK:-}" ] && { echo ">> sem DONE_CHECK: rodou 1x, encerrando."; break; }
  elif rate_limited; then
    wait_reset                                   # dorme e retenta a MESMA iteracao
  else
    echo ">> erro nao relacionado a limite; veja $LOG" >&2; exit 1
  fi
done
