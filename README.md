# claude-loop

Roda uma tarefa no **Claude Code** de forma autônoma e **sobrevive ao estouro do
limite de uso**: quando os tokens acabam, ele lê a hora do reset (`resets 12:30am`),
dorme até lá e retoma de onde parou. Serve para deixar tarefas longas rodando AFK
(overnight, fim de semana) — build de feature, validação em lote, refactor iterativo.

A ideia central: **o estado do trabalho vive em disco** (arquivos + git), não na
sessão. Se o limite matar a invocação, a próxima retomada lê o disco e continua.
Por isso combina muito bem com fluxos em que o progresso fica gravado, como o
[Spec Kit](https://github.com/github/spec-kit) (`tasks.md` com checkboxes).

## Setup do zero (cada máquina precisa disto)

O motor em si não precisa de nada exótico. O que **cada pessoa** configura no
próprio PC/conta:

1. **bash** — Windows: instale o **Git Bash** (https://git-scm.com/download/win).
   macOS/Linux já vêm com bash.
2. **Node.js** (para instalar o CLI) — https://nodejs.org (LTS).
3. **Claude Code CLI**:
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude --version        # confirma a instalação
   ```
4. **Login (individual!)** — rode `claude` uma vez e faça login com a **sua própria
   conta/assinatura** Claude. Este é o passo que não se copia entre máquinas: cada
   um usa e paga a própria conta. Sem login, o loop não roda.

Confira o caminho do CLI se `claude` não estiver no PATH do bash:
```bash
which claude            # Windows: where claude   (ex.: /c/nvm4w/nodejs/claude)
```

`date -d` (parse da hora do reset) já vem no Git Bash e no Linux. No macOS, se o
parse falhar, o loop usa backoff cego automaticamente — ou instale `coreutils`.

> O motor genérico **não** usa `uv`, `ffmpeg`, `python` nem Graphify — isso só é
> necessário em fluxos específicos (visão/vídeo, grafo de código), não aqui.

## Instalação

Copie `claude-loop.sh` para onde quiser e dê permissão de execução:

```bash
chmod +x claude-loop.sh
```

Descubra o caminho do seu `claude` se ele não estiver no PATH:

```bash
which claude            # ou, no Windows: where claude
```

## Uso

```bash
# 1) Rodar um prompt uma vez (resiliente a limite):
./claude-loop.sh "revise o módulo de auth e conserte os testes que falham"

# 2) Rodar até uma condição de parada sua (DONE_CHECK):
#    aqui: repete até não sobrar checkbox aberto em tasks.md
DONE_CHECK='! grep -qE "^\s*-\s*\[ \]" tasks.md' \
  ./claude-loop.sh "/implemente a próxima tarefa não marcada em tasks.md; pare ao concluir uma"

# 3) Escolher modelo e esforço de raciocínio:
MODEL=claude-opus-4-8 EFFORT=max ./claude-loop.sh "refatore o serviço X"
```

### Knobs (variáveis de ambiente)

| Var | Default | O que faz |
|---|---|---|
| `CLAUDE` | `claude` | caminho do CLI (ex.: `/c/nvm4w/nodejs/claude`) |
| `MODEL` | `claude-fable-5` | modelo (`claude-opus-4-8`, `claude-sonnet-5`, …) |
| `EFFORT` | `high` | raciocínio: `low` \| `medium` \| `high` \| `max` |
| `MAX_ITERS` | `50` | teto de iterações (anti-loop-infinito) |
| `DONE_CHECK` | — | comando shell; o loop **para quando ele retorna 0**. Sem isso, roda 1×. |
| `PROMPT_FILE` | — | lê o prompt de um arquivo em vez do argumento |

## Como funciona a resiliência

1. Roda `claude -p --model … --effort … --dangerously-skip-permissions "<prompt>"`.
2. Se a saída contém a mensagem de limite (`hit your limit`, `resets HH:MM`, `429`, `overloaded`…), extrai a hora do reset e **dorme até lá** (+2 min). Se não conseguir ler a hora, cai num backoff de 5 min → 1 h.
3. Retoma a **mesma** iteração. O `DONE_CHECK` decide quando encerrar.

## Padrão avançado: loop fechado "medir → corrigir → remedir"

Para ir além de "faz e para" — iterar até uma **métrica** bater uma meta —, o mesmo
motor serve: seu prompt escreve um `metrics.json`, e um wrapper por fora lê a métrica
e decide continuar. Um exemplo real desse padrão (validar falso-positivos de um
detector e auto-corrigir até a precisão-alvo) vive no projeto que originou este kit;
replique a ideia trocando o prompt e o `DONE_CHECK` por algo como
`DONE_CHECK='python -c "import json,sys; sys.exit(0 if json.load(open(\"metrics.json\"))[\"precision\"]>=0.85 else 1)"'`.

## Segurança (leia antes de rodar)

- **`--dangerously-skip-permissions`**: o agente edita arquivos e roda comandos **sem
  pedir confirmação**. Use só em repo/branch que você controla, de preferência numa
  branch dedicada ou num `git worktree` isolado.
- **Nunca** coloque segredos (tokens, chaves, `.env`) no prompt ou no `PROMPT_FILE` —
  eles iriam parar em logs. Passe segredos por variável de ambiente e leia-os no
  código, não no prompt.
- O loop consome tokens da **sua conta** enquanto roda. Ele é finito (para no
  `DONE_CHECK` ou `MAX_ITERS`), mas rode quando não precisar da conta em paralelo.
- Comece com `MODEL`/`EFFORT` menores para validar o fluxo antes de soltar no caro.

## Licença

Faça o que quiser. Sem garantias.
