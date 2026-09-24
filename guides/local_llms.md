# Using Legion with local LLMs

Legion talks to models through [ReqLLM](https://hexdocs.pm/req_llm), so any
provider ReqLLM supports, Legion can run on - including servers on your own
machine. [Ollama](https://ollama.com) has a native `:ollama` provider and is
the quickest start; [vLLM](https://docs.vllm.ai) has one too, and anything
that speaks the OpenAI Chat Completions API works through the `:openai`
provider with a custom `base_url` - ReqLLM's
[Model Specs](https://hexdocs.pm/req_llm/model-specs.html) guide shows how,
and the [model support](https://hexdocs.pm/req_llm/model-support.html) page
lists every provider it ships with.

## Ollama

1. Install Ollama and pull a model. The server listens on `localhost:11434`:

```sh
ollama pull qwen3:8b
```

2. Point Legion at it, globally or per agent:

```elixir
# config/config.exs
config :legion, :config, %{model: "ollama:qwen3:8b"}

# or per agent, which wins over the global setting
def config, do: %{model: "ollama:qwen3:8b"}
```

   Local model names are not in ReqLLM's catalog, so the first request logs
   an "unverified model" warning. It only means there is no pricing metadata;
   silence it with `config :req_llm, warn_unverified_models: false`.

3. Verify in `iex -S mix`, same as in [Installation](installation.md):

```elixir
Legion.execute(PingAgent, "Return the sum of 2 and 2")
#=> {:ok, "4"}
```

   The first call is slow while Ollama loads the model; later ones are not.

A remote Ollama host is provider config, not model config:

```elixir
config :req_llm, :ollama, base_url: "http://gpu-box:11434/v1"
```

## Picking a model

Everything above the model stays the same - tools, sandboxes, store, rate
limiter, [legion_web](https://github.com/software-mansion/legion_web). What
changes is how much the model has to carry: Legion asks it for structured
JSON on every step, expects working Lua (or Elixir) against tool source it
has just read, and its system prompt is long - every tool's source is in it.
So pick a model that handles structured output and code well, with a context
window to match, and make sure the server is actually configured to use that
window; local servers tend to default to a small one and truncate silently.
A lower `max_iterations` keeps a struggling model from looping for long.
