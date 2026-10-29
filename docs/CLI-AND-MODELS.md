# CLIs and models

Datacore does not ship a model. It drives the ones you already have — either an API key it calls
itself, or an AI coding CLI it dispatches work to. This page covers which CLIs can be dispatched
to, how to configure each, which models to put behind them, and how to run an open-weight model
locally.

Every number here was measured on the machine named beside it. Nothing is estimated.

## First: a provider is not a worker

This is the one distinction worth getting right before you configure anything, because both
commands succeed and they do different things.

| | `datacore provider add <preset>` | `datacore worker add <cli>` |
|---|---|---|
| What it is | an **API key**, stored in your keychain | a **CLI on your PATH** that Datacore launches |
| Who makes the call | Datacore itself | the CLI, under your own login |
| Used for | model calls inside the platform | dispatched work — writing code, reviewing it |
| Shows up in | `datacore provider list` | `datacore worker list` |

**Adding a provider gives you no workers.** If you run `datacore provider add meta`, it will verify
the key, store it, and list Meta under `provider list` — and `datacore worker list` will be
unchanged. Work is dispatched to *workers*. A provider that is not also a worker never receives a
task.

## Which CLIs can be dispatched to

| CLI | Family names | Binary | Roles | Closes its own task |
|---|---|---|---|---|
| Claude Code | `claude-worker`, `claude-review` | `claude` | implementation, rework, review | yes |
| Codex | `codex-worker`, `codex-review` | `codex` | implementation, rework, review | yes |
| AgY | `agy`, `agy-review` | `agy` | implementation, rework, review | **no** — see below |
| Muse Code | — | `muse` | — | **not dispatchable yet** — see below |

`datacore worker add claude` enables one implementation worker and one reviewer for that CLI. The
family name is what `worker list` prints; the binary is what has to resolve on `PATH`.

### AgY works but cannot report back

The Claude and Codex launchers pass each dispatched worker its own MCP configuration, so the worker
can read its task, log evidence and close it. The AgY launcher passes only `--print`,
`--dangerously-skip-permissions`, `--output-format text`, `--model` and `--effort` — no MCP
configuration at all, because AgY registers MCP servers globally (`agy mcp add`) with no
per-invocation flag.

So a dispatched AgY worker **does the work and leaves its task open**. Measured: an AgY worker wrote
its output file and its task stayed `created`, while the equivalent Codex task reached `completed`.
Treat AgY as fire-and-forget and keep lifecycle-closing work on Claude or Codex.

### Muse Code is not dispatchable yet

Muse Code is a capable coding agent and is the right CLI for Meta models, but **Datacore has no
Muse launcher**. The bridge's dispatch switch has exactly three cases — `claude-code`, `codex`,
`agy` — and the capability catalogue the Coordinator selects from is compiled in alongside it.
Consequences:

- `datacore worker add muse` reports `No worker matches 'muse'`.
- Hand-writing a `"cli": "muse"` entry into the worker registry is accepted by the file and then
  fails at dispatch, because no launcher matches it.
- This cannot be fixed by configuration on a fresh machine. It needs a launcher in the bridge.

**What does work today** is Muse as a provider, and Muse driven by hand:

```bash
muse login                                  # account login; no API key needed
datacore provider add meta                  # if you also want Datacore calling the API directly
muse exec --model muse-spark-1.3 'your prompt here'
```

**Adding the launcher is a known-size change, not an open question.** Muse Code already supports
everything a first-class worker needs — more safely than Codex does:

```bash
# Proven against a live Datacore runtime. With a real token this connects;
# with a dummy one it fails on the credential, not the wiring.
DC_TOKEN='Bearer …' muse exec \
  --workspace /path/to/repo --json --yolo \
  --model muse-spark-1.3 \
  -c 'mcpServers.datacore={"url":"http://127.0.0.1:43123/mcp","headers":{"Authorization":"${DC_TOKEN}"}}' \
  'read your task and do it'
```

Note `${DC_TOKEN}`: Muse requires secrets as a whole-value environment reference and **refuses an
inline literal**, so the token never reaches the command line or a process listing. The Codex `-c`
form does not enforce that. A Muse worker would therefore be safer than the ones that exist.

A launcher needs: the argv above, per-dispatch MCP config carrying the worker's own agent id and
tool bundle, catalogue entries with `implementation` and `review` phases, `muse` added to the
CLI→binary map so `worker add muse` resolves, and a `bridge_dispatch:launcher:muse` doctor check.

## Three things gate dispatch, whichever CLI

All three fail quietly, so check them in order:

1. **The binary resolves on `PATH`** — `datacore doctor` checks this and reports
   `bridge_dispatch:launcher:<cli>`.
2. **The CLI is logged in.** Datacore only checks that the command exists; it cannot tell an
   authenticated CLI from one that will refuse on first use. Run the CLI once yourself.
3. **The task's project maps to a git repository** — `datacore project list` / `datacore project link`.

## Models

### Hosted

| Model | Use it for | Notes |
|---|---|---|
| `muse-spark-1.3` | implementation, review, structured output | `muse exec --output-schema FILE` is schema-guaranteed on the meta provider |
| `muse-wonder-1.0` | occasional deep review | expensive; use sparingly |

`muse exec --output-schema` is the reason to prefer the Muse CLI for anything that must return
conforming JSON: the schema is enforced, not requested.

### Local, open-weight

Local models are worth running for three reasons: no per-token cost, no data leaving the machine,
and an independent model for review work. They are not worth running for speed.

## Running a local model

**Recommendation: llama.cpp's `llama-server`.** Reasons, in order:

- It is the fastest of the practical options on Apple Silicon. Ollama **wraps llama.cpp**, so it
  cannot exceed llama.cpp's throughput — it trades a little of it for model management.
- It exposes an OpenAI-compatible endpoint, which is what Datacore's `local` provider preset and
  every OpenAI-compatible client expect.
- It reads GGUF directly, so quantized community builds work without conversion.

MLX is the one alternative that can genuinely beat it on Apple Silicon for some models, but it
needs an MLX conversion of the weights rather than GGUF. It is untested here, so it is listed as
worth measuring, not recommended.

```bash
brew install llama.cpp

# Keep reasoning on and at full strength -- see "If the model is a reasoning model" below.
llama-server -m ~/models/<model>.gguf --port 8080 \
  --ctx-size 16384 \
  --reasoning on --reasoning-effort max --reasoning-budget -1 \
  --reasoning-format deepseek

curl -s http://127.0.0.1:8080/v1/models      # confirm it answers
datacore provider add local                  # preset targets 127.0.0.1:8080
```

`--reasoning-effort` takes `minimal|low|medium|high|xhigh|max`; `--reasoning-budget -1` leaves
thinking unrestricted. Do not trade these away for speed: on a reviewing model the reasoning *is*
the capability you are running it for.

### Measured: Muse Glimmer 30B on an Apple M1 Max

Machine: Apple M1 Max, 10 cores (8P/2E), 64 GB unified memory, 53 GB usable as GPU working set.
Model: `Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf` — 27.85 B parameters, 15.59 GiB on disk.
llama.cpp build 11669 (`620d2225c`), Metal backend, 2 repetitions.

| Setting | Prompt (pp512) | Generation (tg128) |
|---|---|---|
| default | **129.13 ± 0.13 t/s** | **13.09 ± 0.14 t/s** |
| `-fa 1` (flash attention) | 131.27 ± 0.42 t/s | 13.23 ± 0.29 t/s |

Flash attention made **no measurable difference** — both results sit inside each other's error
bars. That is expected: at 15.59 GiB per token-generation pass, 13.09 t/s is about 204 GB/s of
effective memory bandwidth against roughly 400 GB/s theoretical on this chip. The model is
bandwidth-bound, so tuning the attention kernel cannot help much. A smaller quantization or a
smaller model is the only real lever.

### If the model is a reasoning model, budget for the thinking

Muse Glimmer is a reasoning model, and that changes the arithmetic enough to be worth its own
measurement. Same machine, same model, served with the flags above, one advisory critique of a
dataset-quality report:

| | measured |
|---|---|
| wall clock, one critique | **34 s** (a second run at template default: 42 s) |
| completion tokens | 430 (second run: 452) |
| of which reasoning | ~1,450 chars vs ~530 chars of answer — roughly **three quarters** |
| `finish_reason` | `stop` |

Two traps follow, and both look like a broken model rather than a configuration mistake:

- **`content` is empty while the model is still thinking.** Thoughts arrive in
  `message.reasoning_content` and `message.content` fills only once reasoning closes. A call with
  `max_tokens: 200` returned 200 tokens, `finish_reason: length`, and an **empty** `content`. Give a
  reasoning model room — 2,048 or more — or you will get nothing and blame the weights.
- **Per-request attempts to cap thinking were ignored.** Sending `reasoning_budget: 0` and
  `chat_template_kwargs: {"enable_thinking": false}` in the request body produced 1,587 characters
  of reasoning anyway. Reasoning is controlled by the **server flags**, not per call. (Which is
  fine: you want it on.)

### What 13 tokens/second is and is not good for

This is the number that should drive your architecture, so be concrete about it:

- **Good: a reviewer or critic.** Measured above: **about 35 seconds** for a real advisory critique,
  thinking included. That is a perfectly reasonable cost for an independent second opinion, and the
  output quality is worth it.
- **Bad: an implementation worker.** A coding agent emits thousands of tokens per task, reads files
  back, and iterates — and a reasoning model spends three quarters of its tokens before answering.
  At 13 t/s a single 4,000-token response is over five minutes *before* the first tool call. A local
  30 B will be the slowest part of your system by a wide margin.

So: **hosted models for implementation, local open-weight for review.** If you need a local
implementation worker anyway, drop to a much smaller model and expect to trade quality for it.

## Choosing a model per role

| Role | Recommended | Why |
|---|---|---|
| Implementation / rework | hosted `muse-spark-1.3` via Muse Code | fast, schema-guaranteed structured output |
| Review / critique | local open-weight via `llama-server`, reasoning at `max` | independent of the implementer's provider and failure modes; cost-free; ~35 s per critique measured |
| Deep review, occasionally | `muse-wonder-1.0` | expensive — use deliberately |

Keeping review on a different model from implementation is the point, not a detail: a reviewer that
shares the implementer's account and failure modes is not an independent reviewer. This is the same
reason the built-in catalogue warns that `agy-review` is not an independent reviewer of `agy`'s own
work.
