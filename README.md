# agentic-loop

Duas camadas, um objetivo: implementar Spec Kit **sem babá**, com blast radius
limitado e estado em disco (não na sessão).

## Motor vs protocolo

| Camada | O quê | Onde |
|---|---|---|
| **Protocolo (worker)** | 1 task: implement → blind review → commit local | `commands/agentic-loop.md` + `commands/agentic-loop-intake.md` |
| **Motor (driver)** | Loop AFK que sobrevive a rate-limit / reserva horário | `claude-loop.sh` + `render-log.js` |

```text
intake (opcional) → tasks.md
        ↓
  protocolo: /agentic-loop   ← 1 task por invocação
        ↓
  driver: /loop  |  claude-loop.sh (Claude Code AFK)
```

- **Cursor:** use skills + `/loop`. **Não** rode `claude-loop.sh` no Cursor
  (`--dangerously-skip-permissions` é path Claude Code).
- **Claude Code overnight:** `examples/done-check-speckit.sh` (liga
  `STUCK_LOG=.specify/agentic-loop.log` + `DONE_CHECK` nos checkboxes).

Prompt canônico (stack completa): [`prompts/grind-canonical.md`](prompts/grind-canonical.md).

## Setup do zero (Claude Code)

1. **bash** — Windows: [Git Bash](https://git-scm.com/download/win).
2. **Node.js** LTS + `npm install -g @anthropic-ai/claude-code` + login (`claude`).
3. Copie `commands/*.md` → `~/.claude/commands/`.
4. `chmod +x claude-loop.sh examples/done-check-speckit.sh`.

## Uso rápido

```bash
# 1) Um prompt resiliente a limite:
./claude-loop.sh "revise o módulo X e conserte os testes"

# 2) Spec Kit até zerar tasks (recomendado):
./examples/done-check-speckit.sh
# ou manualmente:
STUCK_LOG=.specify/agentic-loop.log \
DONE_CHECK='! grep -qE "^\s*-\s*\[ \]" tasks.md' \
  ./claude-loop.sh "$(sed -n '/^```text$/,/^```$/p' prompts/grind-canonical.md | sed '1d;$d')"
```

### Knobs do motor (`claude-loop.sh`)

| Var | Default | Função |
|---|---|---|
| `CLAUDE` / `MODEL` / `EFFORT` | `claude` / `claude-fable-5` / `high` | CLI |
| `MAX_ITERS` | `50` | teto anti-loop |
| `DONE_CHECK` | — | para quando exit 0; sem isso roda 1× |
| `STUCK_LOG` / `STUCK_LIMIT` | — / `2` | para se o worker repetir bloqueio humano |
| `AVAILABLE_BY` / `AVAILABLE_MIN` / `SAFETY_MARGIN_MIN` | — / `70` / `30` | reserva limite para horário humano |
| `USAGE_FILE` | `~/Desktop/claude-usage/usage_data.json` | widget local |
| `CLAUDE_SESSION_KEY` + `CLAUDE_ORG_ID` | — | API usage (sem gastar tokens) |

Espelho JSON (Cursor / projeto): `examples/agentic-loop.config.json`.

## Segurança

- **`--dangerously-skip-permissions`:** edita e roda comandos sem confirmar.
  Use só em branch/`git worktree` **isolado** que você controla.
- **Nunca** coloque secrets no prompt, `PROMPT_FILE`, ou git.
- **`CLAUDE_SESSION_KEY` / `CLAUDE_ORG_ID`:** cookies da sessão claude.ai.
  Exporte só no shell local / secret store. **Não** versionar. Não colar em
  issues/PRs/logs. Rotacione se vazar. Sem esses vars o motor cai no `USAGE_FILE`.
- O loop gasta tokens da **sua** conta até `DONE_CHECK` / `MAX_ITERS` / reserva.

## Cursor

Ver [`cursor/README.md`](cursor/README.md).

## Licença

MIT — veja [LICENSE](LICENSE). Contribuições: [CONTRIBUTING.md](CONTRIBUTING.md).
