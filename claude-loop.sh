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
#   AVAILABLE_BY hora OPCIONAL (ex.: "10:00") ate quando voce precisa do limite disponivel.
#               Se omitida, o loop nao aplica nenhuma reserva por horario (roda ate DONE_CHECK
#               / MAX_ITERS / rate-limit). Com ela, o loop para de iniciar iteracoes novas
#               SAFETY_MARGIN_MIN antes do horario E prevê, pelo widget de uso, se pelo menos
#               AVAILABLE_MIN% do limite estara disponivel nesse horario (ver AVAILABLE_MIN).
#               Se o horario ja passou hoje, vale pro dia seguinte.
#   SAFETY_MARGIN_MIN margem antes de AVAILABLE_BY p/ parar (default: 30)
#   AVAILABLE_MIN % minimo do limite que precisa estar DISPONIVEL em AVAILABLE_BY (default: 70).
#               O loop para quando prevê que sobraria menos que isso no horario.
#   USAGE_FILE  json do widget de uso local (default: ~/Desktop/claude-usage/usage_data.json).
#   CLAUDE_SESSION_KEY / CLAUDE_ORG_ID  se setados, o loop consulta o MESMO endpoint que o
#               widget usa (GET $CLAUDE_API_BASE/api/organizations/<org>/usage, so cookie de
#               sessao — NAO gasta tokens) e nao depende do widget estar rodando. Sem eles,
#               cai no USAGE_FILE. SESSION_KEY = cookie 'sessionKey' do claude.ai; ORG_ID =
#               cookie 'lastActiveOrg'. CLAUDE_API_BASE default: https://claude.ai
#
# Como prevê a disponibilidade em AVAILABLE_BY (usa o widget): a janela de 5h so zera no
# horario que ela mesma tem marcado (reset_info), consumo nao adianta nem atrasa isso.
#   - Se a janela ATIVA reseta ANTES de AVAILABLE_BY, o uso atual sera zerado a tempo -> ok.
#   - Se ainda estara ativa em AVAILABLE_BY, o uso atual persiste -> disponivel = 100 - uso;
#     para quando isso cai abaixo de AVAILABLE_MIN. Reavalia a cada iteracao (auto-corrige).
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
reset_time_from_log() {
  # extrai a hora do AVISO real de limite ("...hit your ... limit · resets 1:20am") de $1.
  # NAO usa qualquer "resets HH:MM" do log: o conteudo da tarefa pode citar horarios (ex. um
  # doc com "5-hour limit reached - resets 3:00 PM"). Ancora no aviso e pega a ULTIMA
  # ocorrencia (o aviso real vem no fim do stream); so cai no padrao solto se nada casar.
  local rt
  rt=$(grep -oiE "hit your[^\"]*limit[^\"]*resets?[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m" "$1" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | tail -1)
  [ -z "$rt" ] && rt=$(grep -oiE 'resets?[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' "$1" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' | tail -1)
  [ -n "$rt" ] && echo "$rt"
}
wait_reset()   {
  # dorme ate a hora do aviso de limite; se nao parsear, backoff cego
  local rt target now
  rt=$(reset_time_from_log "$RAWLOG")
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
AVAILABLE_MIN="${AVAILABLE_MIN:-70}"
past_cutoff() {
  [ -z "${AVAILABLE_BY:-}" ] && return 1
  local target now cutoff
  target=$(date -d "$AVAILABLE_BY" +%s 2>/dev/null) || return 1
  now=$(date +%s); [ "$target" -le "$now" ] && target=$((target+86400))
  cutoff=$((target - SAFETY_MARGIN_MIN*60))
  [ "$now" -ge "$cutoff" ]
}
CLAUDE_API_BASE="${CLAUDE_API_BASE:-https://claude.ai}"
usage_snapshot() {
  # echo "PCT RESET_EPOCH": uso% da janela de 5h e epoch do proximo reset (0 = desconhecido).
  # Falha (1) se nenhuma fonte responder.
  # Fonte A — API claude.ai (mesmo endpoint do widget; NAO consome tokens): usada quando
  #   CLAUDE_SESSION_KEY + CLAUDE_ORG_ID estao setados. Independe do widget estar rodando.
  # Fonte B — widget local (USAGE_FILE): fallback quando nao ha credenciais da API.
  local now pct resets_at reset_epoch json out secs
  now=$(date +%s)
  if [ -n "${CLAUDE_SESSION_KEY:-}" ] && [ -n "${CLAUDE_ORG_ID:-}" ]; then
    json=$(curl -fsS --max-time 15 \
      -H "anthropic-client-platform: web_claude_ai" \
      -H "Cookie: sessionKey=$CLAUDE_SESSION_KEY" \
      "$CLAUDE_API_BASE/api/organizations/$CLAUDE_ORG_ID/usage" 2>/dev/null) || json=""
    if [ -n "$json" ]; then
      out=$(printf '%s' "$json" | node -e '
        let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
          var f=JSON.parse(s).five_hour||{};
          if(typeof f.utilization==="number") console.log(Math.floor(f.utilization)+" "+(f.resets_at||""));
        }catch(e){}});' 2>/dev/null)
      if [ -n "$out" ]; then
        read -r pct resets_at <<<"$out"
        reset_epoch=0; [ -n "${resets_at:-}" ] && reset_epoch=$(date -d "$resets_at" +%s 2>/dev/null || echo 0)
        echo "$pct $reset_epoch"; return 0
      fi
    fi
  fi
  [ -f "$USAGE_FILE" ] || return 1
  read -r pct secs < <(node -e '
    try {
      var s = require(process.argv[1]).sessao_atual || {};
      var pct = (typeof s.percentual === "number") ? Math.floor(s.percentual) : "";
      var ri = s.reset_info || "", secs = "";
      if (/resetou/i.test(ri)) secs = 0;
      else { var h=/(\d+)\s*h/i.exec(ri), m=/(\d+)\s*min/i.exec(ri); if (h||m) secs=(h?parseInt(h[1],10)*3600:0)+(m?parseInt(m[1],10)*60:0); }
      console.log(pct + " " + secs);
    } catch (e) { console.log(" "); }
  ' "$USAGE_FILE" 2>/dev/null)
  [ -n "${pct:-}" ] || return 1
  reset_epoch=0; [ -n "${secs:-}" ] && reset_epoch=$((now + secs))
  echo "$pct $reset_epoch"
}
avail_at_deadline() {
  # % do limite previsto DISPONIVEL em AVAILABLE_BY; falha se nao der pra prever.
  [ -z "${AVAILABLE_BY:-}" ] && return 1
  local target now snap pct reset_epoch
  target=$(date -d "$AVAILABLE_BY" +%s 2>/dev/null) || return 1
  now=$(date +%s); [ "$target" -le "$now" ] && target=$((target+86400))
  snap=$(usage_snapshot) || return 1
  pct=${snap%% *}; reset_epoch=${snap##* }
  # janela ATIVA reseta antes do deadline -> uso atual sera zerado a tempo -> 100% disponivel
  [ "$reset_epoch" -gt "$now" ] && [ "$reset_epoch" -le "$target" ] && { echo 100; return 0; }
  # janela ainda ativa no deadline -> uso atual persiste
  echo $(( 100 - pct ))
}
not_enough_at_deadline() {
  local avail
  avail=$(avail_at_deadline) || return 1
  [ "$avail" -lt "$AVAILABLE_MIN" ]
}

# CLAUDE_LOOP_LIB=1: so define as funcoes (pro self-test), nao roda o loop.
[ -n "${CLAUDE_LOOP_LIB:-}" ] && return 0 2>/dev/null

iter=0
while : ; do
  if done_check; then echo ">> DONE_CHECK satisfeito; concluido."; break; fi
  if past_cutoff; then echo ">> parando: dentro de ${SAFETY_MARGIN_MIN}min de $AVAILABLE_BY — reservando o limite pra voce."; break; fi
  if not_enough_at_deadline; then echo ">> parando: previsao de $(avail_at_deadline)% disponivel em $AVAILABLE_BY (< ${AVAILABLE_MIN}% exigido) — reservando o limite pra voce."; break; fi
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
