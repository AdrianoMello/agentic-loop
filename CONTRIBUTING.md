# Contributing

## Acesso

- Preferência: collaborator com push em `feature/*` (pedir ao maintainer).
- Sem push: fork → branch `feature/…` ou `hotfix/…` → PR para `AdrianoMello/agentic-loop`.

## Escopo

| Mudança | Onde |
|---|---|
| Protocolo (1 task, review, intake) | `commands/` |
| Motor AFK / rate-limit | `claude-loop.sh`, `render-log.js`, `test-avail.sh` |
| Prompt / exemplos | `prompts/`, `examples/` |
| Notas Cursor | `cursor/` |

Diff mínimo. Sem refactors oportunistas. Teste o que tocars:
`bash test-avail.sh` se alterar previsão de disponibilidade.

## Segurança em PRs

Não inclua `CLAUDE_SESSION_KEY`, `CLAUDE_ORG_ID`, `.env`, nem logs com secrets.
