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
#   # para 30min antes das 10:00 (uso liberado quando voce chegar):
#   AVAILABLE_BY="10:00" ./claude-loop.sh "..."
#
# Knobs (variaveis de ambiente):
#   CLAUDE      caminho do CLI claude          (default: claude no PATH)
#   MODEL       modelo                          (default: claude-fable-5)
#   EFFORT      low | medium | high | max       (default: high)
#   MAX_ITERS   teto de iteracoes               (default: 50)
#   DONE_CHECK  comando shell; o loop PARA quando ele retorna 0 (default: roda 1x e sai)
#   PROMPT_FILE arquivo com o prompt (alternativa ao argumento)
#   LOGDIR      pasta p/ log de cada iteracao (default: ./claude-loop-logs). Por iteracao:
#               iter-NNN.log (legivel: pensamento/texto/tool calls, via render-log.js) e
#               iter-NNN.raw.jsonl (bruto, stream-json completo)
#   STUCK_LOG   arquivo de log do proprio comando (ex.: .specify/agentic-loop.log). Se as
#               ultimas STUCK_LIMIT linhas forem todas bloqueio (nao rate-limit, nao erro —
#               ex. "working tree dirty", "refusing to work unattended"), para o loop: retry
#               nao resolve um bloqueio que só um humano destrava.
#   STUCK_LIMIT quantas linhas de bloqueio seguidas ate desistir (default: 2)
#   AVAILABLE_BY hora (ex.: "10:00") ate quando voce precisa do limite disponivel. O loop
#               para de iniciar iteracoes novas SAFETY_MARGIN_MIN antes desse horario —
#               reserva de proposito, nao tenta prever consumo por iteracao.
#   SAFETY_MARGIN_MIN margem antes de AVAILABLE_BY p/ parar (default: 30)
#   USAGE_FILE  json do widget de uso local (default: ~/Desktop/claude-usage/usage_data.json,
#               se existir). Se o uso atual (sessao_atual.percentual) >= USAGE_THRESHOLD, para
#               na hora — nao espera chegar no AVAILABLE_BY pra reagir a um uso ja alto.
#   USAGE_THRESHOLD % de uso da sessao atual que dispara parada antecipada (default: 90)
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run()          { "$CLAUDE" -p --model "$MODEL" --effort "$EFFORT" --dangerously-skip-permissions --output-format stream-json --verbose "$1" 2>&1 | tee "$RAWLOG" | node "$SCRIPT_DIR/render-log.js" | tee "$LOG"; return "${PIPESTATUS[0]}"; }
rate_limited() { grep -qiE "hit your limit|limit reached|reached .*limit|usage limit|rate limit|resets?[[:space:]]+[0-9]|too many requests|overloaded|429" "$RAWLOG"; }
wait_reset()   {
  # dorme ate a hora que o CLI informa ("resets 12:30am"); se nao parsear, backoff cego
  local rt target now
  rt=$(grep -oiE 'resets?[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' "$RAWLOG" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | head -1)
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
STUCK_LIMIT="${STUCK_LIMIT:-2}"
stuck()        {
  [ -z "${STUCK_LOG:-}" ] && return 1
  [ -f "$STUCK_LOG" ] || return 1
  local tail_lines total blocked
  tail_lines="$(tail -n "$STUCK_LIMIT" "$STUCK_LOG")"
  total=$(printf '%s\n' "$tail_lines" | grep -c .)
  blocked=$(printf '%s\n' "$tail_lines" | grep -ciE 'dirty before start|refusing to work unattended|working tree dirty')
  [ "$total" -ge "$STUCK_LIMIT" ] && [ "$blocked" -eq "$total" ]
}
SAFETY_MARGIN_MIN="${SAFETY_MARGIN_MIN:-30}"
USAGE_FILE="${USAGE_FILE:-$HOME/Desktop/claude-usage/usage_data.json}"
USAGE_THRESHOLD="${USAGE_THRESHOLD:-90}"
past_cutoff() {
  [ -z "${AVAILABLE_BY:-}" ] && return 1
  local target now cutoff
  target=$(date -d "$AVAILABLE_BY" +%s 2>/dev/null) || return 1
  now=$(date +%s); [ "$target" -le "$now" ] && target=$((target+86400))
  cutoff=$((target - SAFETY_MARGIN_MIN*60))
  [ "$now" -ge "$cutoff" ]
}
usage_too_high() {
  [ -f "$USAGE_FILE" ] || return 1
  local pct
  pct=$(node -e '
    try { var p = require(process.argv[1]).sessao_atual.percentual; if (typeof p === "number") console.log(Math.floor(p)); } catch (e) {}
  ' "$USAGE_FILE" 2>/dev/null)
  [ -n "$pct" ] && [ "$pct" -ge "$USAGE_THRESHOLD" ]
}

iter=0
while : ; do
  if done_check; then echo ">> DONE_CHECK satisfeito; concluido."; break; fi
  if past_cutoff; then echo ">> parando: dentro de ${SAFETY_MARGIN_MIN}min de $AVAILABLE_BY — reservando o limite pra voce."; break; fi
  if usage_too_high; then echo ">> parando: uso da sessao atual >= ${USAGE_THRESHOLD}% ($USAGE_FILE) — nao arrisco estourar antes de $AVAILABLE_BY."; break; fi
  iter=$((iter+1)); [ "$iter" -gt "$MAX_ITERS" ] && { echo ">> teto MAX_ITERS=$MAX_ITERS atingido."; break; }
  LOG="$LOGDIR/iter-$(printf '%03d' "$iter").log"
  RAWLOG="$LOGDIR/iter-$(printf '%03d' "$iter").raw.jsonl"
  echo ">> ===== iteracao $iter (log: $LOG) ====="
  if run "$PROMPT"; then
    BACKOFF=300                                  # sucesso: reseta o backoff
    if stuck; then echo ">> travado: ultimas $STUCK_LIMIT linhas de $STUCK_LOG sao bloqueio (nao rate-limit). So um humano resolve — parando."; break; fi
    [ -z "${DONE_CHECK:-}" ] && { echo ">> sem DONE_CHECK: rodou 1x, encerrando."; break; }
  elif rate_limited; then
    wait_reset                                   # dorme e retenta a MESMA iteracao
  else
    echo ">> erro nao relacionado a limite; veja $LOG" >&2; exit 1
  fi
done
