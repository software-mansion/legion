defmodule Legion.Sandbox.Elixir.ASTChecker do
  @moduledoc """
  Static safety check for sandboxed code.

  Parses a code string into an AST and walks every node, rejecting the first
  violation found. The check is **default-deny** for built-in modules: every
  module/function call must be explicitly listed.

  Categories validated:

  - **Bare forms** - non-prefixed calls/identifiers (`if`, `case`, `+`, `fn`,
    `is_atom`, `raise`, ...) must be in `@allowed_bare_forms`. Anything else
    (`def`, `defstruct`, `apply`, `spawn`, `send`, `receive`, `__MODULE__`,
    ...) is rejected.
  - **`Module.function/arity` calls** - the module must be a built-in (with
    the function in that module's allowlist, and the arity within its cap)
    or a caller-supplied tool. Tail aliases match for `__aliases__` nodes
    only, never for atom-literal dispatch (`:"Elixir.Helper".fun(...)`),
    so a tool tail like `System` cannot unlock the real stdlib module.
  - **Arity caps on calendar functions** - the higher arities of `Date.new`,
    `DateTime.shift_zone`, `Time.utc_now`, etc. take a calendar / time-zone
    database module that is dispatched at runtime. The allowlist caps each
    such function at its safe arity; sandboxed code must use the lower-arity
    form or a sigil (`~D`, `~T`, `~U`, `~N`).
  - **Dynamic dispatch** - `expr.fun` / `expr.fun(...)` is rejected outright.
    Literal-module forms (`Mod.fun(...)` and `:mod.fun(...)`) are handled by
    the preceding clauses, so anything reaching the dynamic-dispatch clause
    has a non-literal base. `m.key` map access goes through this check too —
    use `Map.fetch!(m, :key)` or `Map.get(m, :key)`.
  - **`raise` / `reraise`** - the first argument must be a literal alias /
    atom-literal exception module (in `@safe_exceptions`), a binary literal,
    or a string-interpolation. Anything else would force-load an arbitrary
    module at runtime via `mod.exception/1`.
  - **Struct literals** - `%Mod{...}` is rejected unless `Mod` is in
    `@safe_struct_modules`, `@safe_exceptions`, or a tool. The runtime
    force-loads `Mod` and runs its `@on_load`.
  - **Fake structs** - the literal atom `:__struct__` and any binary
    containing the substring `"__struct__"` are rejected. A map with an
    `__struct__` key is dispatched as a struct by every BEAM protocol; the
    binary check covers the `~w(... __struct__)a` materialisation path.

  Built-in modules and their allowed functions are defined in this file.
  Functions that can break out of the sandbox (atom-table churn, dynamic code
  evaluation, code definition, process / message manipulation, time-zone DB
  mutation, ...) are simply not in any allowlist.

  ## Tools (caller-supplied modules)

  Caller-supplied tool modules are **fully trusted**: every function on every
  arity is allowed, and `%Tool{...}` struct literals are allowed. The host is
  responsible for vetting whatever it exposes — if you hand `File`, `System`,
  `Code`, or any other stdlib module to `Legion.Sandbox.Elixir.execute/5` as a
  "tool", you have opted out of the sandbox for that module. Expose a thin
  facade module that wraps only the operations you actually want available.

  Tail-alias collisions are not rejected. A tool named `MyApp.Date` shadows
  stdlib `Date` once the host aliases it in the evaluation env: source-level
  `Date.utc_today()` then routes to the tool, and `raise ArgumentError, "x"`
  with a tool named `MyApp.ArgumentError` routes to the tool's `exception/1`
  instead of stdlib. This is not an RCE escalation (the tool's functions
  are callable directly anyway), but it can produce surprising semantics —
  prefer non-colliding names for tools.

  ## Known limitations

  The check focuses on RCE prevention. It does **not** protect against:

  - Atom-table growth from parsing the code itself: `Code.string_to_quoted/1`
    creates atoms for every identifier (variable name, function name, module
    alias, atom literal) it sees in the source. A pathological input with
    many unique identifiers will inflate the atom table even when every call
    site is denied.
  - Most denial-of-service vectors (CPU, memory, message queue depth,
    long-running comprehensions, ...). `Legion.Sandbox.Runner`'s timeout,
    memory, and reduction budgets are the only mitigation.
  """

  # Bare forms: every non-prefixed call/identifier in user code must resolve
  # to one of these. Anything outside this set (def*, alias/import/require/use,
  # quote, apply, spawn*, send, receive, __ENV__/__MODULE__/__CALLER__/etc,
  # binding, var!, alias!, dbg, super) is rejected.

  @allowed_special_forms ~w(
    __aliases__ __block__ -> <- |
    {} %{} <<>>
    fn case cond if unless for with try when
    = ^ :: .. ..// \\ &
  )a

  @allowed_kernel_operators ~w(
    + - * / ** ++ -- <> == != === !== =~ < > <= >= && || ! and or not in |>
  )a

  @allowed_kernel_guards ~w(
    is_atom is_binary is_bitstring is_boolean is_exception is_float
    is_function is_integer is_list is_map is_map_key is_nil is_non_struct_map
    is_number is_pid is_port is_reference is_struct is_tuple
  )a

  # Note: `sigil_w` and `sigil_W` are listed here so non-`a` modifier uses
  # (`~w(foo bar)`, `~w(foo bar)s`, `~w(foo bar)c`) pass the bare-form check.
  # The `a` modifier is intercepted by a dedicated clause below — interpolation
  # is rejected outright (the resulting atoms would be built from runtime
  # strings, defeating literal-atom inspection); non-interpolated tokens are
  # only checked for the `"__struct__"` literal, since every other resulting
  # atom is inert (see the `check_atom_sigil/2` clause for why).
  # `size` and `unit` appear in the AST as bare-form calls inside `<<>>`
  # bitstring segments (e.g. `<<x::size(8)-unit(4)>>`). Outside `<<>>` they
  # don't resolve to anything (no `Kernel.size/1`), so allowing them is a
  # no-op for non-bitstring code.
  @allowed_kernel_macros_and_funs ~w(
    abs binary_part binary_slice bit_size byte_size ceil div elem floor
    get_and_update_in get_in hd inspect length make_ref map_size max min
    pop_in put_elem put_in rem round self tap then tl to_charlist
    to_string to_timeout trunc tuple_size update_in
    raise reraise throw exit
    match? if unless tap then
    size unit
    sigil_C sigil_D sigil_N sigil_R sigil_S sigil_T sigil_U
    sigil_c sigil_r sigil_s sigil_w sigil_W
  )a

  @allowed_bare_forms MapSet.new(
                        @allowed_special_forms ++
                          @allowed_kernel_operators ++
                          @allowed_kernel_guards ++
                          @allowed_kernel_macros_and_funs
                      )

  # Built-in modules with per-function allowlists.

  # Kernel: notably absent are spawn*, send, receive, apply, def*, *_to_atom*,
  # function_exported?, macro_exported?, var!, alias!, binding, dbg, use,
  # spawn_request, and `node` (the node atom is needed to forge a valid
  # `%File.Stream{}` on distributed VMs). `raise`/`reraise` are also absent:
  # they're handled only via bare forms gated by the dedicated clauses below;
  # `Kernel.raise` (or `&Kernel.raise/1`) would bypass the `@safe_exceptions`
  # check.
  @kernel_allowed ~w(
    abs binary_part binary_slice bit_size byte_size ceil div elem exit floor
    get_and_update_in get_in hd inspect length make_ref map_size max min
    pop_in put_elem put_in rem round self tap then throw tl
    to_charlist to_string to_timeout trunc tuple_size update_in
    match? if unless in tap then
    is_atom is_binary is_bitstring is_boolean is_exception is_float
    is_function is_integer is_list is_map is_map_key is_nil is_non_struct_map
    is_number is_pid is_port is_reference is_struct is_tuple
    + - * / ** ++ -- <> == != === !== =~ < > <= >= && || ! and or not |>
    sigil_C sigil_D sigil_N sigil_R sigil_S sigil_T sigil_U
    sigil_c sigil_r sigil_s sigil_w sigil_W
  )a

  @string_allowed ~w(
    at bag_distance byte_slice capitalize chunk codepoints contains?
    count downcase duplicate ends_with? equivalent? first graphemes
    jaro_distance last length match? myers_difference next_codepoint
    next_grapheme next_grapheme_size normalize pad_leading pad_trailing
    printable? replace replace_invalid replace_leading replace_prefix
    replace_suffix replace_trailing reverse slice split split_at splitter
    starts_with? to_charlist to_float to_integer trim
    trim_leading trim_trailing upcase valid? valid_character?
  )a

  @enum_allowed ~w(
    all? any? at chunk_by chunk_every chunk_while concat count count_until
    dedup dedup_by drop drop_every drop_while each empty? fetch fetch! filter
    find find_index find_value flat_map flat_map_reduce frequencies
    frequencies_by group_by intersperse into join map map_every
    map_intersperse map_join map_reduce max max_by member? min min_by
    min_max min_max_by partition product product_by random reduce reduce_while
    reject reverse reverse_slice scan shuffle slice slide sort sort_by split
    split_while split_with sum sum_by take take_every take_random take_while
    to_list uniq uniq_by unzip with_index zip zip_reduce zip_with
  )a

  # Map: `keys` and `to_list` are absent — they leak `:__struct__` from any
  # struct value, which sandboxed code could then route through `Map.put` to
  # build a fake struct (e.g. forge `%File.Stream{}` to write files via `for
  # ..., into:`). `values/1` is kept: it doesn't expose the `:__struct__` key,
  # which is the literal needed to repopulate the struct slot.
  #
  # `map`, `filter`, `reject`, `split_with`, `merge/3`, and `intersect/3` are
  # absent for the same reason by a different route: applied to a struct they
  # hand the raw `{:__struct__, Mod}` pair (or the bare key) to a user callback,
  # which can `throw` the key out to recover the atom at runtime — defeating the
  # literal `:__struct__` check and re-enabling struct forging. Their `Enum`
  # equivalents raise on structs (structs aren't `Enumerable`), so route map
  # transforms through `Enum` and rebuild with `Map.new/1`. The callback-free
  # `merge/2` and `intersect/2` are capped in and kept.
  @map_allowed ~w(
    delete drop equal? fetch fetch! from_keys from_struct get
    get_and_update get_and_update! get_lazy has_key?
    new pop pop! pop_lazy put put_new put_new_lazy replace replace!
    replace_lazy size split take update update! values
  )a ++ [{:merge, 2}, {:intersect, 2}]

  @mapset_allowed ~w(
    delete difference disjoint? equal? filter intersection member? new put
    reject size split_with subset? symmetric_difference to_list union
  )a

  # List: `to_atom` / `to_existing_atom` are omitted — the latter lets
  # sandboxed code reconstruct `:__struct__` from bytewise-built charlists,
  # defeating the literal-atom rejection.
  @list_allowed ~w(
    ascii_printable? delete delete_at duplicate ends_with? first flatten foldl
    foldr improper? insert_at keydelete keyfind keyfind! keymember? keyreplace
    keysort keystore keytake last myers_difference pop_at replace_at
    starts_with? to_charlist to_float to_integer to_string
    to_tuple update_at wrap zip
  )a

  @keyword_allowed ~w(
    delete delete_first drop equal? fetch fetch! filter from_keys get
    get_and_update get_and_update! get_lazy get_values has_key? intersect
    keys keyword? map merge new pop pop! pop_first pop_lazy pop_values put
    put_new put_new_lazy reject replace replace! replace_lazy size split
    split_with take to_list update update! validate validate! values
  )a

  @tuple_allowed ~w(append delete_at duplicate insert_at product sum to_list)a

  @integer_allowed ~w(
    digits extended_gcd floor_div gcd is_even is_odd mod parse pow to_charlist
    to_string undigits
  )a

  @float_allowed ~w(
    ceil floor max_finite min_finite parse pow ratio round to_charlist to_string
  )a

  # Atom: only conversions away from atoms.
  @atom_allowed ~w(to_charlist to_string)a

  # Regex: compile/compile! are safe; the regex engine is bounded.
  @regex_allowed ~w(
    compile compile! escape match? named_captures names opts re_pattern
    recompile recompile! regex? replace run scan source split version
  )a

  @range_allowed ~w(disjoint? new range? shift size split to_list)a

  @access_allowed ~w(all at at! elem fetch fetch! filter find get get_and_update
                     key key! pop slice values)a

  @stream_allowed ~w(
    chunk_by chunk_every chunk_while concat cycle dedup dedup_by drop
    drop_every drop_while duplicate each filter flat_map from_index
    intersperse interval into iterate map map_every reject repeatedly
    resource run scan take take_every take_while timer transform unfold
    uniq uniq_by with_index zip zip_with
  )a

  # Calendar-module functions need per-arity caps: the higher arity often
  # takes a calendar / time-zone-database module that is dispatched at
  # runtime, force-loading the module (and running its `@on_load`). The
  # `{:func, max_arity}` form caps `func` at that arity; bare atoms allow
  # any arity. `convert/2` and `compatible_calendars?/2` are entirely absent
  # because every arity of those takes a calendar module.
  @date_allowed [
    :after?,
    :before?,
    :beginning_of_month,
    :beginning_of_week,
    :compare,
    :day_of_era,
    :day_of_week,
    :day_of_year,
    :days_in_month,
    :diff,
    :end_of_month,
    :end_of_week,
    :leap_year?,
    :months_in_year,
    :quarter_of_year,
    :range,
    :shift,
    :to_erl,
    :to_gregorian_days,
    :to_iso8601,
    :to_iso_days,
    :to_string,
    :year_of_era,
    :add,
    {:from_erl, 1},
    {:from_erl!, 1},
    {:from_gregorian_days, 1},
    {:from_iso8601, 1},
    {:from_iso8601!, 1},
    {:new, 3},
    {:new!, 3},
    {:utc_today, 0}
  ]

  @datetime_allowed [
    :after?,
    :before?,
    :compare,
    :diff,
    :to_date,
    :to_gregorian_seconds,
    :to_iso8601,
    :to_naive,
    :to_string,
    :to_time,
    :to_unix,
    :truncate,
    {:add, 3},
    {:from_gregorian_seconds, 2},
    {:from_iso8601, 1},
    {:from_naive, 2},
    {:from_naive!, 2},
    {:from_unix, 2},
    {:from_unix!, 2},
    {:new, 3},
    {:new!, 3},
    {:now, 1},
    {:now!, 1},
    {:shift, 2},
    {:shift_zone, 2},
    {:shift_zone!, 2},
    {:utc_now, 0}
  ]

  @naive_datetime_allowed [
    :after?,
    :before?,
    :beginning_of_day,
    :compare,
    :diff,
    :end_of_day,
    :shift,
    :to_date,
    :to_erl,
    :to_gregorian_seconds,
    :to_iso8601,
    :to_string,
    :to_time,
    :truncate,
    :add,
    {:from_erl, 2},
    {:from_erl!, 2},
    {:from_gregorian_seconds, 2},
    {:from_iso8601, 1},
    {:from_iso8601!, 1},
    {:local_now, 0},
    {:new, 7},
    {:new!, 7},
    {:utc_now, 0}
  ]

  @time_allowed [
    :after?,
    :before?,
    :compare,
    :diff,
    :shift,
    :to_erl,
    :to_iso8601,
    :to_seconds_after_midnight,
    :to_string,
    :truncate,
    :add,
    {:from_erl, 2},
    {:from_erl!, 2},
    {:from_iso8601, 1},
    {:from_iso8601!, 1},
    {:from_seconds_after_midnight, 2},
    {:new, 4},
    {:new!, 4},
    {:utc_now, 0}
  ]

  # Calendar: read-only and module-arg-free. `compatible_calendars?/2` is
  # absent (both args are calendar modules); `put_time_zone_database/1`
  # mutates global env.
  @calendar_allowed ~w(get_time_zone_database strftime truncate)a

  @math_allowed ~w(
    acos acosh asin asinh atan atan2 atanh ceil cos cosh erf erfc exp floor
    fmod log log10 log2 pi pow sin sinh sqrt tan tanh tau
  )a

  # JSON: pure data in/out, no atoms materialised by default.
  @json_allowed ~w(decode decode! encode! encode_to_iodata!)a

  # URI: pure data. `default_port/2` is omitted (the 2-arity form mutates a
  # global scheme->port table); both arities share the name.
  @uri_allowed ~w(
    append_query char_reserved? char_unescaped? char_unreserved?
    decode decode_query decode_www_form encode encode_query
    encode_www_form merge new new! parse query_decoder to_string
  )a

  # Only `:erlang.float_to_binary/2` (fixed-precision float formatting); other
  # erlang BIFs are blocked.
  @erlang_allowed ~w(float_to_binary)a

  # Stdlib struct modules safe in the `%Mod{...}` form. Any other module would
  # be force-loaded at runtime (running its `@on_load`). All listed modules
  # are pure data structs preloaded in a normal Elixir runtime.
  @safe_struct_modules MapSet.new([
                         Date,
                         DateTime,
                         NaiveDateTime,
                         Time,
                         Range,
                         Regex,
                         MapSet,
                         Version,
                         Version.Requirement,
                         URI
                       ])

  # Exception modules safe as the first arg to `raise`/`reraise`. Any other
  # module would be force-loaded at runtime via `Mod.exception/1`.
  @safe_exceptions MapSet.new([
                     ArgumentError,
                     ArithmeticError,
                     BadArityError,
                     BadBooleanError,
                     BadFunctionError,
                     BadMapError,
                     BadStructError,
                     CaseClauseError,
                     CondClauseError,
                     ErlangError,
                     FunctionClauseError,
                     KeyError,
                     MatchError,
                     Protocol.UndefinedError,
                     RuntimeError,
                     SystemLimitError,
                     TryClauseError,
                     UndefinedFunctionError,
                     WithClauseError
                   ])

  # Per-module allowlist: function -> :any (any arity) or non_neg_integer
  # (max allowed arity). Source format mixes bare atoms (any arity) and
  # `{atom, max_arity}` tuples; both are normalised at compile time.
  build_allowlist = fn entries ->
    Map.new(entries, fn
      func when is_atom(func) -> {func, :any}
      {func, max_arity} when is_atom(func) and is_integer(max_arity) -> {func, max_arity}
    end)
  end

  @builtin_module_functions %{
    Kernel => build_allowlist.(@kernel_allowed),
    String => build_allowlist.(@string_allowed),
    Enum => build_allowlist.(@enum_allowed),
    Map => build_allowlist.(@map_allowed),
    MapSet => build_allowlist.(@mapset_allowed),
    List => build_allowlist.(@list_allowed),
    Keyword => build_allowlist.(@keyword_allowed),
    Tuple => build_allowlist.(@tuple_allowed),
    Integer => build_allowlist.(@integer_allowed),
    Float => build_allowlist.(@float_allowed),
    Atom => build_allowlist.(@atom_allowed),
    Regex => build_allowlist.(@regex_allowed),
    Range => build_allowlist.(@range_allowed),
    Access => build_allowlist.(@access_allowed),
    Stream => build_allowlist.(@stream_allowed),
    Date => build_allowlist.(@date_allowed),
    DateTime => build_allowlist.(@datetime_allowed),
    NaiveDateTime => build_allowlist.(@naive_datetime_allowed),
    Time => build_allowlist.(@time_allowed),
    Calendar => build_allowlist.(@calendar_allowed),
    JSON => build_allowlist.(@json_allowed),
    URI => build_allowlist.(@uri_allowed),
    :math => build_allowlist.(@math_allowed),
    :erlang => build_allowlist.(@erlang_allowed)
  }

  @max_code_size 64 * 1024

  # An atom that could refer to an Elixir / Erlang module: rules out `nil`,
  # `true`, `false`, which are atoms but not module references. Used wherever
  # an AST position can hold either a module-atom literal or one of those
  # three special atoms.
  defguardp is_module_atom(x) when is_atom(x) and x not in [nil, true, false]

  @doc """
  Validates `code_string` against the safety rules.

  `allowed_modules` are caller-supplied tool modules. They are trusted: any
  function on them may be called. Both fully-qualified names (`MyApp.Helper`)
  and their tail aliases (`Helper`) are recognised - the same tail mapping
  `Legion.Sandbox.Elixir` puts into the evaluation env's aliases, so both
  spellings validate and resolve to the tool.

  Returns `:ok` or `{:error, reason}` on the first violation (or parse error).
  """
  def check(code_string, _allowed_modules) when not is_binary(code_string) do
    {:error, "code must be a binary, got: #{inspect(code_string)}"}
  end

  def check(code_string, _allowed_modules)
      when byte_size(code_string) > @max_code_size do
    {:error, "code exceeds maximum size of #{@max_code_size} bytes"}
  end

  def check(code_string, allowed_modules) do
    case Code.string_to_quoted(code_string) do
      {:ok, ast} ->
        tools = {
          MapSet.new(allowed_modules),
          MapSet.new(
            for module <- allowed_modules, elixir_module?(module), do: alias_tail(module)
          )
        }

        {_ast, result} = Macro.prewalk(ast, :ok, &check_node(&1, &2, tools))

        result

      {:error, {_meta, message, token}} ->
        {:error, "Parse error: #{message}#{token}"}
    end
  end

  defp alias_tail(module),
    do: module |> Module.split() |> List.last() |> List.wrap() |> Module.concat()

  defp elixir_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.")

  # AST walker. Clause order is load-bearing: the capture clause must precede
  # the variable clause, and the `:__struct__` / binary-literal leaf clauses
  # must come after the bare-form clause.

  defp check_node(node, {:error, _} = error, _tools), do: {node, error}

  # `Foo.bar(args)` - alias form. Tail aliases match (callers can write a
  # tool's short name).
  defp check_node({{:., _, [{:__aliases__, _, parts}, func]}, _, args} = node, :ok, tools)
       when is_list(args) do
    check_module_call(node, Module.concat(parts), func, length(args), tools, :alias_form)
  end

  # `:atom_mod.bar(args)` - atom-literal form. Tail aliases do *not* match,
  # so a tool tail like `System` cannot unlock `:"Elixir.System"`.
  defp check_node({{:., _, [module, func]}, _, args} = node, :ok, tools)
       when is_atom(module) and is_list(args) do
    check_module_call(node, module, func, length(args), tools, :atom_form)
  end

  # `var.fun(args)` / `m.key` / `&m.fun/n` - dynamic dispatch. If `var` is a
  # module atom at runtime, this calls arbitrary code on that module.
  defp check_node({{:., _, [base, func]}, meta, args} = node, :ok, _tools)
       when is_list(args) do
    {node, {:error, dynamic_dispatch_error(base, func, args, meta)}}
  end

  # `f.(args)` anonymous-function invocation, and the bare `:.` dot head that
  # the prewalk visits on its own. The surrounding dot-call clauses already
  # validated anything reachable through these.
  defp check_node({{:., _, [_]}, _, _args} = node, :ok, _tools), do: {node, :ok}
  defp check_node({:., _, _} = node, :ok, _tools), do: {node, :ok}

  # Special context macros parsed as zero-arity identifiers - reject so they
  # don't slip through the variable clause below.
  defp check_node({form, _, context} = node, :ok, _tools)
       when is_atom(context) and
              form in [:__ENV__, :__MODULE__, :__CALLER__, :__DIR__, :__STACKTRACE__] do
    {node, {:error, "#{form} is not allowed"}}
  end

  # `&Mod.fun/arity` - qualified remote capture. The inner dot node is also
  # visited by the prewalk, but it sees `arity = length(args) = 0`, so the
  # arity caps on calendar functions (`Date.new/4`, `DateTime.shift_zone/3`,
  # ...) would slip through and the captured function could later be invoked
  # via `f.(..., MyCalendar)`. Re-run the module-call check with the
  # *captured* arity to plug that. The variable-base form (`&v.fun/n`) is
  # rejected by the dynamic-dispatch clause when the inner dot is visited.
  defp check_node(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, func]}, _, []}, arity]}]} = node,
         :ok,
         tools
       )
       when is_integer(arity) do
    check_module_call(node, Module.concat(parts), func, arity, tools, :alias_form)
  end

  defp check_node(
         {:&, _, [{:/, _, [{{:., _, [module, func]}, _, []}, arity]}]} = node,
         :ok,
         tools
       )
       when is_atom(module) and is_integer(arity) do
    check_module_call(node, module, func, arity, tools, :atom_form)
  end

  # `&name/arity` - local/imported capture. Must precede the variable clause:
  # the inner `{name, _, ctx}` would otherwise match it (since `is_atom(nil)`
  # is true), letting captures of denied imports (`&apply/3`, `&send/2`,
  # `&binding/0`, `&dbg/1`, ...) become invokable via `f.(...)`.
  #
  # `&raise/n` / `&reraise/n` are explicitly denied even though they're in
  # `@allowed_bare_forms`: the capture form passes its first argument at
  # runtime, sidestepping the `@safe_exceptions` gate.
  defp check_node({:&, _, [{:/, _, [{name, _, context}, arity]}]} = node, :ok, _tools)
       when is_atom(name) and is_atom(context) and is_integer(arity) do
    cond do
      name in [:raise, :reraise] ->
        {node,
         {:error,
          "&#{name}/#{arity} is not allowed " <>
            "(would bypass the safe-exception module check at runtime)"}}

      MapSet.member?(@allowed_bare_forms, name) ->
        {node, :ok}

      true ->
        {node, {:error, "&#{name}/#{arity} is not allowed"}}
    end
  end

  # Variable reference - always safe (it's not a call).
  defp check_node({name, _, context} = node, :ok, _tools)
       when is_atom(name) and is_atom(context),
       do: {node, :ok}

  # `%Mod{...}` struct literal. The runtime force-loads `Mod` (and runs its
  # `@on_load`), so `Mod` must be a known-safe struct, safe exception, or
  # tool. Tail-alias matching is alias-form-only.
  defp check_node({:%, _, [{:__aliases__, _, parts}, _map]} = node, :ok, tools),
    do: check_struct_literal(node, Module.concat(parts), tools, :alias_form)

  defp check_node({:%, _, [module, _map]} = node, :ok, tools) when is_module_atom(module),
    do: check_struct_literal(node, module, tools, :atom_form)

  # `raise <arg>, ...` / `reraise <arg>, ...`. The first argument is gated;
  # trailing args are recursed by the prewalk. Anything other than a literal
  # alias / atom-literal exception module, binary, or `<<>>` interpolation is
  # rejected — at runtime `Kernel.raise/2` would call `mod.exception/1` on
  # whatever module atom `<arg>` evaluates to and force-load it. Verified
  # bypass shapes (all rejected here): `v = :m; raise v`, `raise hd([M])`,
  # `raise (fn -> M end).()`, `raise Map.get(%{a: M}, :a)`, `raise tool.fun()`.
  defp check_node({form, _, [arg | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] do
    {node, check_raise_arg(form, arg)}
  end

  # `~w(...)a` / `~W(...)a` — atom-list sigils. The `a` modifier maps each
  # split token through `String.to_atom/1` at macro-expansion time (which
  # runs AFTER the AST check, inside `Code.eval_string`).
  #
  # With INTERPOLATION, the resulting atoms are built from runtime strings
  # the static check can't see — verified RCE chain:
  #
  #     s = "_" <> "_str" <> "uct__"; ~w(#{s})a   # produces :__struct__
  #     ~w(Elixir.File.Stream)a                    # produces File.Stream
  #
  # Combined via `Map.put`, these forge a `%File.Stream{}` map, which
  # `for ..., into:` turns into arbitrary file write. Reject interpolated
  # forms outright.
  #
  # Without interpolation, only the `"__struct__"` token needs rejection:
  # every other resulting atom is an inert value with nowhere dangerous to
  # flow. The dot-call, struct-literal, and raise positions all reject
  # non-literal module/exception args, so a runtime atom can't reach them;
  # the calendar arity caps eliminate the calendar-arg flow.
  defp check_node({sigil, _, [{:<<>>, _, segments}, modifiers]} = node, :ok, tools)
       when sigil in [:sigil_w, :sigil_W] and is_list(modifiers) and is_list(segments) do
    if ?a in modifiers do
      {node, check_atom_sigil(segments, tools)}
    else
      {node, :ok}
    end
  end

  # Bare-form call - catches `def`, `defstruct`, `apply`, `spawn`, `send`,
  # `receive`, `binding`, `var!`, `dbg`, ... (anything not in
  # `@allowed_bare_forms`).
  defp check_node({name, _, args} = node, :ok, _tools)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(@allowed_bare_forms, name) do
      {node, :ok}
    else
      {node, {:error, bare_form_denied_error(name)}}
    end
  end

  # Reject the literal atom `:__struct__` and any binary that *contains* the
  # substring `"__struct__"`. A map with an `__struct__` key is dispatched as
  # a struct by every BEAM protocol — fake `%File.Stream{}` via `for ...,
  # into: fake` writes arbitrary files. The substring check (not equality)
  # blocks `~w(_a __struct__)a` and friends, where `sigil_w` with `a` maps
  # tokens through `String.to_atom/1` at macro-expansion time.
  defp check_node(:__struct__ = node, :ok, _tools),
    do: {node, {:error, "literal :__struct__ atom is not allowed"}}

  defp check_node(node, :ok, _tools) when is_binary(node) do
    if String.contains?(node, "__struct__") do
      {node,
       {:error,
        ~S|literal binary containing "__struct__" is not allowed | <>
          "(would materialise the :__struct__ atom via sigil_w/sigil_W " <>
          "with the `a` modifier at macro-expansion time)"}}
    else
      {node, :ok}
    end
  end

  defp check_node(node, acc, _tools), do: {node, acc}

  # Interpolated `~w(...)a` is rejected outright (the resulting atoms are
  # built from runtime strings the static check can't see). Non-interpolated
  # is checked token-by-token: only `"__struct__"` is rejected — every other
  # token's resulting atom is just an inert value with nowhere dangerous to
  # flow (raise / struct / dot-call positions all reject non-literal args,
  # and the calendar arity gate eliminates the calendar-arg flow).
  defp check_atom_sigil(segments, _tools) do
    cond do
      Enum.any?(segments, &(not is_binary(&1))) ->
        {:error,
         "~w/~W with the `a` modifier and interpolation is not allowed - the " <>
           "resulting atoms are built from runtime strings, bypassing the static " <>
           "`:__struct__` literal check. Use a list literal (`[:foo, :bar]`) or " <>
           "a non-`a` sigil (`~w(foo bar)`)."}

      "__struct__" in (segments |> Enum.join() |> String.split()) ->
        {:error,
         ~S|~w/~W token "__struct__" is not allowed - the `a` modifier would | <>
           "materialise the `:__struct__` atom, which is the literal needed to " <>
           "forge a fake struct via `Map.put`."}

      true ->
        :ok
    end
  end

  defp check_module_call(node, module, func, arity, {tool_modules, tool_aliases}, form) do
    in_tools? =
      MapSet.member?(tool_modules, module) or
        (form == :alias_form and MapSet.member?(tool_aliases, module))

    cond do
      in_tools? ->
        {node, :ok}

      not Map.has_key?(@builtin_module_functions, module) ->
        {node, {:error, module_denied_error(module)}}

      true ->
        {node, check_builtin_call(module, func, arity)}
    end
  end

  defp check_builtin_call(module, func, arity) do
    case Map.fetch(@builtin_module_functions[module], func) do
      :error -> {:error, function_denied_error(module, func)}
      {:ok, :any} -> :ok
      {:ok, max_arity} when arity <= max_arity -> :ok
      {:ok, _max_arity} -> {:error, arity_capped_error(module, func, arity)}
    end
  end

  defp arity_capped_error(Map, func, arity) when func in [:merge, :intersect] do
    "Map.#{func}/#{arity} is not allowed - its callback receives every common " <>
      "key, which leaks the internal `:__struct__` key of any struct value. " <>
      "Use `Map.#{func}/2` and resolve key conflicts beforehand."
  end

  defp arity_capped_error(module, func, arity) do
    "#{inspect(module)}.#{func}/#{arity} is not allowed in the sandbox - " <>
      "this arity takes a calendar / time-zone-database module argument that " <>
      "would be force-loaded at runtime. Use a lower-arity form, or build " <>
      "dates / times via sigils (`~D`, `~T`, `~U`, `~N`)."
  end

  defp check_struct_literal(node, module, {tool_modules, tool_aliases}, form) do
    in_tools? =
      MapSet.member?(tool_modules, module) or
        (form == :alias_form and MapSet.member?(tool_aliases, module))

    if in_tools? or MapSet.member?(@safe_struct_modules, module) or
         MapSet.member?(@safe_exceptions, module) do
      {node, :ok}
    else
      {node, {:error, struct_literal_error(module)}}
    end
  end

  defp check_raise_arg(form, {:__aliases__, _, parts}),
    do: check_raise_module(form, Module.concat(parts))

  defp check_raise_arg(form, module) when is_module_atom(module),
    do: check_raise_module(form, module)

  defp check_raise_arg(_form, arg) when is_binary(arg), do: :ok
  defp check_raise_arg(_form, {:<<>>, _, _segments}), do: :ok

  defp check_raise_arg(form, _arg) do
    {:error,
     "#{form} requires a literal exception module from the safe-exceptions " <>
       "allowlist or a literal string; dynamic / indirected first arguments " <>
       "are rejected (would force-load arbitrary modules at runtime)"}
  end

  defp check_raise_module(form, module) do
    if MapSet.member?(@safe_exceptions, module),
      do: :ok,
      else: {:error, "#{form} of #{inspect(module)} is not allowed"}
  end

  @module_hint %{
    IO =>
      "return values from your code instead of printing them; the host displays them automatically",
    Code => "dynamic code evaluation is not permitted",
    Process => "process / message manipulation is not permitted",
    File =>
      "file I/O is not permitted (ask the caller for a tool that exposes the data you need)",
    System => "host introspection / shell-out is not permitted",
    :erlang => "only :erlang.float_to_binary/2 is exposed; other erlang BIFs are blocked"
  }

  defp module_denied_error(module) do
    hint =
      Map.get(
        @module_hint,
        module,
        "the host only exposes a fixed set of safe stdlib modules plus the tools you were given"
      )

    "Module #{inspect(module)} is not allowed in the sandbox - #{hint}"
  end

  defp function_denied_error(Map, func) when func in [:keys, :to_list] do
    "Map.#{func} is not allowed - it would leak the :__struct__ atom from " <>
      "any struct value. Use `Map.values/1` or `Enum.map(map, fn {k, _} -> k end)`."
  end

  defp function_denied_error(Map, func) when func in [:map, :filter, :reject, :split_with] do
    "Map.#{func} is not allowed - its callback receives the `{:__struct__, Mod}` " <>
      "pair of any struct value. Use `Enum.#{func}/2` and rebuild with `Map.new/1`."
  end

  defp function_denied_error(module, func)
       when module in [Atom, String, List] and func in [:to_atom, :to_existing_atom] do
    "#{inspect(module)}.#{func} is not allowed - dynamic atom construction can " <>
      "grow the atom table or reconstruct denied atoms."
  end

  defp function_denied_error(Kernel, :apply) do
    "Kernel.apply is not allowed - call the function directly: `Module.fun(arg1, arg2)`."
  end

  defp function_denied_error(Kernel, :raise) do
    "Kernel.raise is not allowed - use the bare form `raise ExceptionModule, \"msg\"` " <>
      "with a stdlib exception, or `raise \"msg\"`."
  end

  defp function_denied_error(Kernel, func) when func in [:send, :spawn] do
    hint =
      case func do
        :send -> "inter-process messaging is not permitted in the sandbox."
        :spawn -> "process creation is not permitted in the sandbox."
      end

    "Kernel.#{func} is not allowed - #{hint}"
  end

  defp function_denied_error(module, func) do
    "#{inspect(module)}.#{func} is not allowed in the sandbox"
  end

  defp struct_literal_error(module) do
    "%#{inspect(module)}{} is not allowed - the runtime would force-load " <>
      "#{inspect(module)} (and run its `@on_load`). Allowed: " <>
      "#{inspect(MapSet.to_list(@safe_struct_modules))}, safe stdlib " <>
      "exceptions, and tool modules. For pattern matching, use a plain map " <>
      "pattern (`%{key: val}`)."
  end

  defp dynamic_dispatch_error(base, func, args, meta) do
    location = if line = meta[:line], do: " on line #{line}", else: ""
    base_description = describe_dispatch_base(base)
    no_parens? = Keyword.get(meta, :no_parens, false)

    expression =
      cond do
        no_parens? -> "#{base_description}.#{func}"
        args == [] -> "#{base_description}.#{func}()"
        true -> "#{base_description}.#{func}(...)"
      end

    "dynamic dispatch `#{expression}`#{location} is not allowed - if " <>
      "#{base_description} is a module atom at runtime, this calls arbitrary " <>
      "code on that module. Use `Map.fetch!(#{base_description}, :#{func})` " <>
      "or `Map.get(#{base_description}, :#{func})` for map / struct fields."
  end

  defp describe_dispatch_base({name, _, context}) when is_atom(name) and is_atom(context),
    do: Atom.to_string(name)

  defp describe_dispatch_base(_), do: "expression"

  @def_forms ~w(def defp defmodule defmacro defmacrop defstruct defexception
                defprotocol defimpl defdelegate defguard defguardp defoverridable)a
  @directive_forms ~w(alias import require use)a
  @spawn_forms ~w(spawn spawn_link spawn_monitor)a
  @msg_forms ~w(send receive)a
  @macro_forms ~w(quote unquote unquote_splicing)a

  defp bare_form_hint(name) when name in @def_forms,
    do:
      "module / function definitions are not permitted. Use anonymous functions (`fn x -> ... end`) and `Enum.reduce/3` for stateful or recursive logic."

  defp bare_form_hint(name) when name in @directive_forms,
    do:
      "module directives are managed by the sandbox host. Tools are already aliased; reference them directly."

  defp bare_form_hint(:apply),
    do:
      "dynamic dispatch on a runtime module/function atom is not permitted. Call the function directly: `Module.fun(arg1, arg2)`."

  defp bare_form_hint(name) when name in @spawn_forms,
    do: "process creation is not permitted in the sandbox."

  defp bare_form_hint(name) when name in @msg_forms,
    do: "inter-process messaging is not permitted in the sandbox."

  defp bare_form_hint(:binding),
    do:
      "the sandbox host displays available bindings to you separately; reference variables by name."

  defp bare_form_hint(:dbg),
    do: "debug printing is not available; return values from your code instead."

  defp bare_form_hint(name) when name in @macro_forms,
    do: "macro / AST manipulation is not permitted in the sandbox."

  defp bare_form_hint(name),
    do:
      "if this is a function name, prefix it with its module (e.g. `Kernel.#{name}/1`); otherwise it is not permitted."

  defp bare_form_denied_error(name),
    do: "#{name} is not allowed in the sandbox - #{bare_form_hint(name)}"
end
