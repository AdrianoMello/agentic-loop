# Cursor path (não use o bash motor aqui)

No **Cursor**, o driver é a skill `/loop` + `/agentic-loop` (ou Automations).
`claude-loop.sh` com `--dangerously-skip-permissions` é só para **Claude Code** AFK.

## Instalação rápida

1. Copie `commands/agentic-loop.md` e `commands/agentic-loop-intake.md` para
   skills Cursor (ex.: `~/.cursor/skills/agentic-loop/SKILL.md`) ou mantenha
   o espelho já adaptado no seu `~/.cursor/skills/`.
2. Copie `examples/agentic-loop.config.json` →
   `~/.cursor/standards/agentic-loop.config.json` (e/ou `.specify/` no projeto).
3. No Cursor: `usage_guard: false` (não há widget de sessão 5h).
4. Knobs espelhados do motor bash:
   - `available_by` / `available_min` / `safety_margin_min` → reserva humana (só
     relevante se um driver externo consultar usage; no Cursor costuma ficar `null`)
   - `stuck_log` / `stuck_limit` → o worker já escreve `.specify/agentic-loop.log`;
     o bash `STUCK_*` lê o mesmo arquivo quando você usa `claude-loop.sh`

## Grind

Siga `prompts/grind-canonical.md`.
