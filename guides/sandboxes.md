# Sandboxes

Legion runs model-written code in `Legion.Sandbox.Lua` by default - no
configuration needed. `Legion.Sandbox.Elixir` also ships as an opt-in, and
custom sandboxes implement the `Legion.Sandbox` behaviour. To opt in, set the
`sandbox` config key:

```elixir
# globally
config :legion, :config, %{sandbox: Legion.Sandbox.Elixir}

# or per agent, overriding the global setting
def config, do: %{sandbox: Legion.Sandbox.Elixir}
```

## Security boundary

With `Legion.Sandbox.Lua`, generated code runs inside
[lua](https://hexdocs.pm/lua), a Lua 5.3 VM written in pure Elixir. Lua code
cannot refer to anything on the host: it cannot name a module the agent
doesn't list, touch a process or force-load anything. The only way out of
the VM is through the tool functions Legion bridges in, so the attack
surface is your tools plus bugs in the VM. Identifiers and strings stay
binaries inside the VM, so Lua never creates atoms and the atom-table
exhaustion the Elixir sandbox leaves open doesn't apply.

With `Legion.Sandbox.Elixir`, generated code is host code.
`Code.eval_string/3` runs it on the BEAM with the full language, and an AST
checker rejects dangerous forms before evaluation. The checker is an
allowlist, and every module, function, arity, struct literal and sigil in
the stdlib is a potential escape that has to be reviewed. It covers the
known RCE classes but cannot rule out new ones.

## Language and stdlib

| | `Legion.Sandbox.Elixir` | `Legion.Sandbox.Lua` |
|---|---|---|
| Language | Elixir minus denied forms | Lua 5.3 |
| Stdlib | Allowlisted `Enum`, `String`, `Map`, `JSON`, `URI`, `:math`, ... | `string`, `table`, `math`, `utf8` |
| Blocked | - | `io`, `file`, `os.getenv`, `os.execute`, `require`, `load`, `print` |
| Regex | `Regex` (PCRE) | Lua patterns (`string.match`) |
| JSON | `JSON` | None; expose a tool |
| Dates | `Date`, `DateTime` and the rest of the calendar modules | `os.date`, `os.time`, `os.difftime`, `os.clock` |
| State between runs | All bindings persist | Global data persists; locals, functions and metatables don't |
| Result | Last expression | Explicit `return` |

Each run restores Lua globals into a fresh VM as plain data (strings,
numbers, booleans and tables), so a helper function has to be redefined in
every chunk that uses it.

## Calling tools from Lua

Every tool call encodes its arguments from Lua to Elixir and its result
back. Both directions lose information:

- **Tools receive string-keyed maps.** `{date = "..."}` arrives as
  `%{"date" => ...}`, never `%{date: ...}`. A tool that pattern-matches on
  atom keys works in the Elixir sandbox and breaks in Lua. This is the most
  common breakage when reusing existing tools.
- **Tuples become arrays.** `{:ok, 42}` arrives as `["ok", 42]`, and an API
  that takes tuples receives two-element lists. `Legion.Tools.AgentTool`'s
  `parallel` and `pipeline` accept `[agent, task]` pairs; any other
  tuple-shaped tool needs the same treatment or a Lua-friendly wrapper.
- **Atoms become strings and structs become plain tables.** Structs are
  flattened with `Map.from_struct/1`, so the module is lost and internal
  fields such as a `Date`'s `calendar` cross too. Return only the fields the
  model needs.
- **Functions become `nil`.** Other values the VM can't encode, such as pids
  and refs, raise a runtime error that goes back to the model.
- **The empty table is ambiguous.** It decodes as `[]`, so a tool can't tell
  an empty list from an empty map.
- **Only `use Legion.Tool` modules expose functions.** Other modules the
  agent lists, such as sub-agents and extra allowed modules, appear as tables
  with no functions. Any listed module can still be passed where Elixir
  expects one: `AgentTool.call(PlannerAgent, task)` hands the tool the
  `PlannerAgent` atom. Modules the agent doesn't list can't be named.
- **Tool docs are Elixir source.** The model has to translate signatures to
  Lua. For complex tools, define `description/1`, which receives the active
  sandbox, and return Lua examples when it is `Legion.Sandbox.Lua`.

## Chaining tools

Lua can't construct structs, so a struct returned by one tool reaches the
next as a plain map, and `def associate(%Post{} = post, _)` will never
match. Chains that pass rich values between tools use one of these
patterns:

- **Pass ids** (recommended). Tools exchange identifiers and refetch
  internally, so Lua only ever holds scalars.
- **Plain maps.** Tools that accept the string-keyed maps they return
  compose freely, and the model can filter and reshape between calls.
- **Rehydrate at the boundary.** The tool accepts the map and rebuilds its
  struct, which also validates the input. Use this when the model needs to
  read or transform the fields.
- **Opaque handles.** Keep the value on the host, in an ETS table scoped to
  the conversation or in the store, and return a token plus the fields the
  model may read. Later tools resolve the token back to the original term.
  This is the only option for values the bridge can't encode, such as pids,
  refs and connections. Handles outlive a single run, so scope them to the
  conversation, clean them up when it ends, and answer a stale token with an
  error the model can act on.

## Performance and limits

Both sandboxes run under `Legion.Sandbox.Runner` with the same limits:
`sandbox_timeout`, `sandbox_max_heap` (off-heap binaries included),
`sandbox_max_reductions` and `sandbox_priority`.

Both sandboxes interpret the model's code, but in the Elixir sandbox a call
like `Enum.sum/1` hands the bulk of the work to compiled stdlib code. In
Lua, a loop over data runs entirely in the interpreter and costs far more.
Budgets tuned for the Elixir sandbox, especially `sandbox_max_reductions`,
may need raising. Tools run in the same process and count towards the same
budget, but as compiled code they spend far fewer reductions on the same
work, so heavy data processing belongs in them.

The Lua VM also caps string building: concatenation and `string.rep` reject
results larger than half of `sandbox_max_heap` (256 MiB at most) and raise a
catchable "resulting string too large" error instead of hitting the heap
kill. Other string functions are bounded only by the runner.

## What neither sandbox gives you

Both run inside your application's VM. Tool code runs with full host
privileges, scheduler time is shared, and memory use is bounded only by the
runner limits. The Lua sandbox closes language-level escapes; it doesn't
limit what your tools can do. `AgentTool`, HTTP tools and database tools are
as dangerous as what they expose.

Full isolation requires a separate BEAM node, which gives up the direct
access to your application that makes Legion tools useful.

## Choosing a sandbox

Use `Legion.Sandbox.Elixir` when you trust the model and need rich data
manipulation. Use `Legion.Sandbox.Lua` when the code is less trusted or the
tool surface is small and well-defined, and write its tools to accept string
keys and return no tuples.
