# Sandboxes

Legion evaluates LLM-generated code through a pluggable sandbox, selected with
the `sandbox` config key:

```elixir
# globally
config :legion, :config, %{sandbox: Legion.Sandbox.Lua}

# or per agent, which wins over the global setting
def config, do: %{sandbox: Legion.Sandbox.Lua}
```

Two implementations ship with Legion: `Legion.Sandbox.Lua` (the default)
and `Legion.Sandbox.Elixir`. Custom sandboxes implement the `Legion.Sandbox`
behaviour. Both built-ins run under `Legion.Sandbox.Runner`, so the
operational limits (`sandbox_timeout`, `sandbox_max_heap`,
`sandbox_max_reductions`, `sandbox_priority`) behave identically.

## The core difference: where the security boundary sits

**`Legion.Sandbox.Elixir`** - generated code *is* host code. `Code.eval_string/3`
runs it on the BEAM with full language power, and safety comes from the AST
checker rejecting dangerous forms before evaluation. The boundary is a
deny-by-default allowlist over the entire Elixir surface - every module,
function, arity, struct literal, and sigil the stdlib offers is a potential
escape hatch that has to be reasoned about. The checker is hardened against
the known RCE classes, but it is structurally a cat-and-mouse game.

**`Legion.Sandbox.Lua`** - generated code runs inside
[lua](https://hexdocs.pm/lua), a Lua 5.3 VM implemented in pure Elixir. Lua code has no representation for anything on the host: it cannot
name a module, build an atom, touch a process, or force-load anything. The
only doors out of the VM are the tool functions Legion explicitly bridges in.
The residual attack surface is your tools plus bugs in the VM. This makes it the safer choice for less trusted code.

A useful side effect: Lua code cannot create atoms at all (identifiers and
strings stay binaries inside the VM), so the atom-table-growth DoS vector the
Elixir sandbox documents as unsolved does not exist there.

## What the model can do inside

| | `Legion.Sandbox.Elixir` | `Legion.Sandbox.Lua` |
|---|---|---|
| Language | Elixir minus denied forms | Lua 5.3 semantics |
| Stdlib | Allowlisted `Enum`, `String`, `Map`, `Date`/`DateTime`, `Regex`, `JSON`, `URI`, `:math`, ... | Lua's `string`, `table`, `math`; `os.time`/`os.date` (`io`, `file`, `os.getenv`/`os.execute`, `require`, `load`, `print` are blocked) |
| Regex | Full `Regex` / PCRE | Lua patterns only (`string.match`) - weaker |
| JSON | Built-in `JSON` module | None - expose a tool if agents need it |
| Dates | Rich calendar modules | `os.date` / `os.time` only |
| State between executions | All bindings persist | Only **globals** persist; `local`s vanish per chunk |
| Result | Last expression | Explicit `return` required |

## The bridge, and what gets lost crossing it

Tools are Elixir; in the Lua sandbox the model calls them from Lua. Every call
crosses an encode/decode boundary, and that boundary is lossy in both
directions:

- **Tools receive string-keyed maps.** `{date = "..."}` arrives as
  `%{"date" => ...}`, never `%{date: ...}`. A tool that pattern-matches atom
  keys works in the Elixir sandbox and breaks in Lua. This is the single most
  likely thing to bite when reusing existing tools.
- **Tuples do not exist in Lua.** Results like `{:ok, 42}` arrive as the
  array `["ok", 42]`; tuple-taking APIs receive 2-element lists.
  `Legion.Tools.AgentTool.parallel/2` and `pipeline/1` normalise
  `[agent, task]` pairs, but any other tuple-shaped tool API needs the same
  treatment or a Lua-friendly facade.
- **Atoms become strings, structs become plain field tables** (module
  identity dropped - and the flattening is `Map.from_struct/1`, so internal
  fields like a `Date`'s `calendar` cross too; project the fields the model
  needs in the tool if that matters). Function values are silently dropped -
  they encode as `nil` rather than crossing into Lua as callables - and
  anything else the VM cannot encode, such as pids and refs, is a runtime
  error fed back to the model.
- **The empty table is ambiguous**: it decodes as `[]`, so a tool cannot
  tell "empty list" from "empty map".
- **Module references** work only for bridged tools: passing a tool's global
  table where an Elixir module is expected
  (`AgentTool.call(PlannerAgent, task)`) resolves to the module atom. There
  is no general way to name an arbitrary Elixir module - which is a feature.
- **Only `use Legion.Tool` modules expose functions.** Anything else in the
  list (sub-agent modules, extra allowed modules) is bridged reference-only:
  a table carrying just the module marker, with no callable functions.
- **Tool docs are Elixir source** while the model writes Lua, so it must
  translate signatures. Models handle this well, but hand-written
  `description/0` overrides with Lua examples help for complex tools.

## Chaining tools

A struct one tool returns crosses into Lua as a string-keyed field table and
can only come back as a plain map - `def associate(%Post{} = post, _)` never
matches again, and no model retry can fix it, because Lua cannot construct a
struct. Chains that pass rich values between tools need one of these shapes:

- **Plain maps chain as-is.** Tools that accept the string-keyed maps they
  emit compose freely; the model can filter and reshape between calls.
- **Pass ids** (the default): tools exchange identifiers and refetch
  internally, so Lua only ever holds scalars.
- **Rehydrate at the boundary**: the tool accepts the map and rebuilds its
  struct inside - a few lines that double as input validation - for when the
  model must inspect or transform payload fields in Lua.
- **Opaque handles**: park the value host-side (an ETS table scoped per
  conversation, or the store) and return a token plus the fields the model
  may read; later tools resolve the token back to the exact original term.
  The only option for values the bridge cannot encode at all - pids, refs,
  connections. Handles outlive a single eval, so give them a lifecycle:
  scope by conversation, clean up when it ends, and answer a stale token
  with an error message the model can react to.

## Performance and limits

Both sandboxes run under the same `Legion.Sandbox.Runner` (timeout,
`max_heap` plus off-heap binary polling, `max_reductions`, priority), so
operational limits are identical. But the Lua VM interprets on the BEAM -
the same computation costs roughly one to two orders of magnitude more time
and reductions than native Elixir. Budgets tuned for the Elixir sandbox
(especially `sandbox_max_reductions`) may need raising, and heavy in-sandbox
data crunching is better pushed into tools.

The Lua sandbox adds one deterministic guard of its own: the VM refuses to
build any single string larger than half the `max_heap` budget, so a string
bomb comes back as a catchable "resulting string too large" error instead of
racing the heap kill mid-allocation.

Bindings are the user's globals exported as plain data - strings, numbers,
booleans, and tables as maps or lists. Each evaluation starts a fresh VM and
restores them, so functions and metatables do not survive between
executions: a helper must be redefined in every chunk that uses it.

## What neither sandbox gives you

Both still execute inside your application's VM: tool code runs with full
host privileges, scheduler time is shared, and memory is consumed until
limits kill the eval. The Lua sandbox removes the *language-level* escape
routes, not the blast radius of a badly designed tool - `AgentTool`, HTTP
tools, and DB tools are exactly as dangerous as what you expose through them.
Full isolation still means a separate BEAM instance, but this undermines the concept
of Legion's shared resources and easily accessible (and thus powerful) tools.

**Rule of thumb:** use `Legion.Sandbox.Elixir` for trusted generators that
need rich data manipulation; use `Legion.Sandbox.Lua` when the code is less
trusted or the tool surface is small and well-defined - and design tools for
Lua consumption (string keys in, no tuples out).
