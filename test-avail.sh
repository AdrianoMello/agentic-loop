#!/usr/bin/env bash
# self-test da previsao de disponibilidade em AVAILABLE_BY (avail_at_deadline / not_enough_at_deadline)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export USAGE_FILE="$TMP/usage.json"

mkusage() { printf '{"sessao_atual":{"percentual":%s,"reset_info":"%s"}}\n' "$1" "$2" > "$USAGE_FILE"; }
soon="$(date -d '+2 hours' +%H:%M)"   # 2h a frente: janela que reseta ja em <2h zera a tempo
near="$(date -d '+30 minutes' +%H:%M)" # 30min a frente: janela que so reseta em 23h ainda estara ativa

CLAUDE_LOOP_LIB=1 source "$DIR/claude-loop.sh" "x" >/dev/null 2>&1

# 1) janela reseta antes do deadline -> 100% disponivel, independente do uso
mkusage 45 "1min"; AVAILABLE_BY="$soon" avail_at_deadline | grep -qx 100 || { echo "FAIL: reset-antes deveria dar 100"; exit 1; }

# 2) janela ainda ativa no deadline -> disponivel = 100 - uso
mkusage 45 "23h"; got=$(AVAILABLE_BY="$near" avail_at_deadline); [ "$got" = 55 ] || { echo "FAIL: persiste deveria dar 55, deu $got"; exit 1; }

# 3) not_enough dispara quando disponivel < AVAILABLE_MIN (default 70)
mkusage 45 "23h"; AVAILABLE_BY="$near" not_enough_at_deadline || { echo "FAIL: 55%<70% deveria parar"; exit 1; }
mkusage 10 "23h"; AVAILABLE_BY="$near" not_enough_at_deadline && { echo "FAIL: 90%>=70% nao deveria parar"; exit 1; }

# 4) sem AVAILABLE_BY -> nenhuma parada por uso
mkusage 99 "23h"; not_enough_at_deadline && { echo "FAIL: sem deadline nao deveria parar"; exit 1; }

# 5) fonte API (curl mockado): usa five_hour.utilization/resets_at em vez do widget
export CLAUDE_SESSION_KEY=x CLAUDE_ORG_ID=y
resets="$(date -d '+23 hours' +%Y-%m-%dT%H:%M:%S)"   # janela ainda ativa no deadline
curl() { printf '{"five_hour":{"utilization":45,"resets_at":"%s"}}\n' "$resets"; }
rm -f "$USAGE_FILE"   # sem widget: prova que nao depende dele
got=$(AVAILABLE_BY="$near" avail_at_deadline); [ "$got" = 55 ] || { echo "FAIL: API deveria dar 55, deu $got"; exit 1; }
unset -f curl; unset CLAUDE_SESSION_KEY CLAUDE_ORG_ID

echo "OK"
