# Prompt canônico do grind (1 Spec Kit task)

Use este texto como corpo do prompt (Claude Code via `claude-loop.sh`, ou
equivalente no Cursor `/agentic-loop`). Uma invocação = **no máximo uma** task.

```text
Execute /agentic-loop (ou o protocolo em commands/agentic-loop.md) para a
próxima task pendente em tasks.md. Ordem obrigatória nesta task:

1. Spec Kit — ler plan.md/spec.md da feature; implementar só o primeiro `- [ ] T\d+`.
2. TDD — teste que falha → mínimo que passa → verde. Sem suite ornamental.
3. Ponytail — YAGNI → reuse → stdlib → diff mínimo. Sem abstração especulativa.
4. claude-mem — 3 camadas só se houver contexto útil: search → timeline → get_observations.
5. graphify — só se o grafo existir E o match for ambíguo; `--budget` baixo.
6. Blind review — subagent fresco com task + git diff + spec/plan → PASS|FAIL.
   Se subagent indisponível: testes verdes + checklist pai; nunca pular review.
7. Commit local `[agentic-loop] {id}: {short}` se PASS. Sem push/PR.

Pare ao concluir uma task (ou ao bloquear). Logue em `.specify/agentic-loop.log`.
```

## Drivers

| Ambiente | Como rodar |
|---|---|
| Claude Code (interativo) | `/loop /agentic-loop` |
| Claude Code (AFK / overnight) | ver `examples/done-check-speckit.sh` |
| Cursor | skill `/agentic-loop` + `/loop` — **não** usar `claude-loop.sh` |
