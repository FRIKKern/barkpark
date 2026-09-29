defmodule Barkpark.Plugins.HookPayloadShapeTest do
  @moduledoc """
  THE SHAPE CONTRACT BETWEEN THE DISPATCHER AND EVERY `before_publish` HEAD.

  `Content.Lifecycle.publish_after_gate/5` fires `:before_publish` with
  `doc: %Content.Document{}` — a STRUCT, atom keys. A handler headed on
  `%{doc: %{"type" => "task"}}` — a STRING-keyed map — never matches, so every
  publish falls through to the `_payload -> :ok` catch-all and the gate is
  INERT. That is what `Barkpark.Plugins.Tasks.portable_brief_gate/1` did from
  the day it was written: its own unit tests were green because they called it
  with a hand-built string-keyed map, and `:ok` is also what the catch-all
  returns, so no test anywhere could tell a reached gate from a skipped one.

  This test is the missing connection. For EVERY module that
  `use Barkpark.Plugin` and registers a `:before_publish` hook, it proves the
  handler REACHES a non-catch-all clause on the payload shape the dispatcher
  actually fires. It does that by reading the handler's clause HEADS out of the
  source and evaluating each head as a pattern against the real payload — not by
  calling the hook and reading its return value, because the return value is the
  one thing that cannot distinguish the two outcomes.

  The population is DERIVED, never listed: the same rule
  `scripts/roster-drift-check.sh` uses (a real `use Barkpark.Plugin` at the start
  of a line, in a maxdepth-1 file list of `api/lib/barkpark/plugins/*.ex`), and
  an empty derivation REFUSES rather than passing vacuously.

  The scanner is itself under control: `hook_payload_shape_fixture_plugins.exs`
  carries three handlers whose verdicts are known in advance (string-keyed only,
  struct-only, shape-agnostic) and the same scanner must return exactly those
  verdicts in BOTH directions. A scanner that answers "matched" for everything,
  or "no match" for everything, fails there before its verdict about the real
  plugins is believed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document

  @plugins_dir Path.expand("../../../lib/barkpark/plugins", __DIR__)
  @lifecycle_source Path.expand("../../../lib/barkpark/content/lifecycle.ex", __DIR__)
  @fixture_source Path.expand("hook_payload_shape_fixture_plugins.exs", __DIR__)

  # The payload the dispatcher fires. `assert_payload_shape_matches_lifecycle/0`
  # below re-derives the key set and the `doc:` binding from lifecycle.ex itself,
  # so this literal cannot drift away from the code it stands in for.
  defp real_payload do
    %{
      event: :before_publish,
      doc: %Document{
        doc_id: "task-shape-probe",
        type: "task",
        dataset: "production",
        status: "draft",
        content: %{"brief" => %{"version" => 1, "blocks" => []}}
      },
      dataset: "production",
      prev_doc: %Document{doc_id: "task-shape-probe", type: "task"},
      ctx: %{}
    }
  end

  # The shape the old Tasks gate matched — and the shape nothing on the publish
  # path has ever produced.
  defp string_keyed_payload do
    %{
      event: :before_publish,
      doc: %{
        "_id" => "task-shape-probe",
        "type" => "task",
        "content" => %{"brief" => %{"version" => 1, "blocks" => []}}
      },
      dataset: "production",
      prev_doc: %{"type" => "task"},
      ctx: %{}
    }
  end

  describe "the scanner itself (positive control)" do
    test "the fixture heads are classified in BOTH directions" do
      handlers = before_publish_handlers(@fixture_source)

      assert Map.keys(handlers) |> Enum.sort() ==
               [:both_shapes_gate, :forbidden_string_keyed_gate, :struct_only_gate],
             "the fixture file no longer offers the three control heads: #{inspect(Map.keys(handlers))}"

      struct_verdicts =
        Map.new(handlers, fn {name, cs} -> {name, reaches?(cs, real_payload())} end)

      string_verdicts =
        Map.new(handlers, fn {name, cs} -> {name, reaches?(cs, string_keyed_payload())} end)

      IO.puts("""

      POSITIVE CONTROL — fixture heads (#{@fixture_source})
        on the REAL (struct) payload:        #{inspect(struct_verdicts)}
        on the hand-built string-keyed one:  #{inspect(string_verdicts)}
      """)

      # The forbidden head — the one the Tasks gate carried — MUST be flagged on
      # the real payload. This is the arm that proves the test can see a shape
      # mismatch at all.
      refute struct_verdicts.forbidden_string_keyed_gate,
             "a `%{doc: %{\"type\" => \"task\"}}` head was reported as REACHED on the " <>
               "struct payload — the scanner cannot see the very mismatch it exists to catch"

      # ...and the mirror, so "flagged" is not simply what it always answers.
      assert string_verdicts.forbidden_string_keyed_gate,
             "the scanner reports the string-keyed head unreachable on a string-keyed " <>
               "payload — it is red for everything, which is not a detector"

      assert struct_verdicts.struct_only_gate
      refute string_verdicts.struct_only_gate

      assert struct_verdicts.both_shapes_gate
      assert string_verdicts.both_shapes_gate
    end

    test "a catch-all clause is never counted as reaching the handler" do
      handlers = before_publish_handlers(@fixture_source)

      # Every fixture handler HAS a `_payload -> :ok` catch-all, and every one of
      # them returns :ok on both payloads. If catch-alls counted, all six
      # verdicts above would be `true` and the control would be blind.
      assert Enum.all?(handlers, fn {_name, clauses} ->
               Enum.any?(clauses, fn {pattern, _guard} -> catch_all?(pattern) end)
             end),
             "the fixture handlers lost their catch-all clauses; the control no longer " <>
               "proves catch-alls are excluded"

      refute reaches?(Map.fetch!(handlers, :forbidden_string_keyed_gate), real_payload())
    end
  end

  describe "the dispatcher payload" do
    test "lifecycle.ex still fires :before_publish with the struct-bound doc this test builds" do
      source = File.read!(@lifecycle_source)

      assert source =~ "defp publish_after_gate(%Document{} = draft",
             "publish_after_gate/5 no longer heads on %Document{} = draft — re-derive the " <>
               "payload this test builds from whatever it heads on now"

      payload_block =
        Regex.run(~r/payload = %\{(.*?)\n    \}/s, source)
        |> case do
          [_, body] -> body
          _ -> flunk("could not find the `payload = %{...}` literal in #{@lifecycle_source}")
        end

      assert payload_block =~ "event: :before_publish"

      assert payload_block =~ "doc: draft",
             "the :before_publish payload no longer binds `doc:` to the %Document{} head " <>
               "variable — this test's real_payload/0 is stale: #{payload_block}"

      for key <- Map.keys(real_payload()) do
        assert payload_block =~ "#{key}:",
               "lifecycle.ex's payload has no `#{key}:` key; real_payload/0 has drifted"
      end
    end
  end

  describe "every registered before_publish handler" do
    test "reaches a non-catch-all clause on the payload the dispatcher fires" do
      population = plugin_modules()

      refute population == [],
             "derived ZERO plugin modules from #{@plugins_dir}. An empty population would " <>
               "agree with an empty expectation and pass silently — the derivation went dark."

      registered =
        for {mod, path} <- population,
            handlers = before_publish_handlers(path),
            handlers != %{},
            do: {mod, path, handlers}

      refute registered == [],
             "derived #{length(population)} plugin modules but ZERO :before_publish handlers. " <>
               "Either every gate was deleted or the capture extraction stopped seeing them."

      IO.puts("""

      POPULATION — modules that `use Barkpark.Plugin` (#{length(population)}):
        #{population |> Enum.map(fn {m, _} -> inspect(m) end) |> Enum.join(", ")}

      REGISTERED :before_publish handlers (#{registered |> Enum.flat_map(fn {_, _, h} -> Map.keys(h) end) |> length()}):
      #{registered |> Enum.map(fn {m, _, h} -> "  #{inspect(m)}: #{h |> Map.keys() |> Enum.map_join(", ", &"#{&1}/1")}" end) |> Enum.join("\n")}
      """)

      payload = real_payload()

      failures =
        for {mod, _path, handlers} <- registered,
            {name, clauses} <- handlers,
            not reaches?(clauses, payload) do
          heads =
            clauses
            |> Enum.reject(fn {p, _g} -> catch_all?(p) end)
            |> Enum.map_join("\n      ", fn {p, _g} -> Macro.to_string(p) end)

          "  #{inspect(mod)}.#{name}/1 — no non-catch-all clause matches the fired payload." <>
            "\n    non-catch-all heads:\n      #{heads}"
        end

      assert failures == [],
             """
             These :before_publish handlers never reach their own gate. The dispatcher fires
             `doc: %Barkpark.Content.Document{}` (a STRUCT, atom keys); these heads match some
             other shape, so every publish falls through to the `_payload -> :ok` catch-all and
             the gate is INERT — returning exactly the :ok a passing gate returns.

             #{Enum.join(failures, "\n")}
             """
    end

    test "each source-derived capture list agrees with what the module registers at runtime" do
      # The scan reads captures out of `lifecycle_hooks/0`'s literal. If a plugin
      # ever builds its hook list dynamically, the literal yields fewer (or zero)
      # captures and this test would silently scan nothing — so the count is
      # checked against the live map.
      for {mod, path} <- plugin_modules() do
        Code.ensure_loaded!(mod)

        runtime =
          if function_exported?(mod, :lifecycle_hooks, 0) do
            mod.lifecycle_hooks() |> Map.get(:before_publish, []) |> length()
          else
            0
          end

        scanned = before_publish_handlers(path) |> map_size()

        assert scanned == runtime,
               "#{inspect(mod)} registers #{runtime} :before_publish hook(s) at runtime but the " <>
                 "source scan found #{scanned}. The hook list is no longer a literal list of " <>
                 "`&name/1` captures, so this test is not seeing every handler."
      end
    end
  end

  # ── Population derivation ────────────────────────────────────────────────
  # Same rule as scripts/roster-drift-check.sh: a REAL `use Barkpark.Plugin` at
  # the start of a line (never one quoted inside a @moduledoc example), over a
  # maxdepth-1 file list (never a glob that crosses `/` into plugins/registry/).

  defp plugin_modules do
    @plugins_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(&Path.join(@plugins_dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn path ->
      File.read!(path) =~ ~r/^[[:space:]]*use Barkpark\.Plugin([,[:space:]]|$)/m
    end)
    |> Enum.map(fn path -> {module_name(path), path} end)
  end

  defp module_name(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk(nil, fn
      {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil ->
        {node, Module.concat(parts)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> case do
      nil -> flunk("no defmodule found in #{path}")
      mod -> mod
    end
  end

  # ── Source scan ──────────────────────────────────────────────────────────

  # %{handler_name => [{pattern_ast, guard_ast_or_nil}]} for every handler this
  # file registers under :before_publish.
  defp before_publish_handlers(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    names = registered_capture_names(ast)
    clauses = clauses_by_name(ast)

    Map.new(names, fn name ->
      {name,
       Map.get(clauses, name) ||
         flunk("#{path} registers &#{name}/1 under :before_publish but defines no #{name}/1")}
    end)
  end

  defp registered_capture_names(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:before_publish, list} = node, acc when is_list(list) ->
          {node, acc ++ Enum.flat_map(list, &capture_name/1)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  defp capture_name({:&, _, [{:/, _, [{name, _, ctx}, 1]}]}) when is_atom(name) and is_atom(ctx),
    do: [name]

  defp capture_name(_), do: []

  defp clauses_by_name(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, _body]} = node, acc when kind in [:def, :defp] ->
          case normalize_head(head) do
            {name, pattern, guard} ->
              {node, Map.update(acc, name, [{pattern, guard}], &(&1 ++ [{pattern, guard}]))}

            :skip ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp normalize_head({:when, _, [inner, guard]}) do
    case normalize_head(inner) do
      {name, pattern, nil} -> {name, pattern, guard}
      other -> other
    end
  end

  defp normalize_head({name, _, [arg]}) when is_atom(name), do: {name, arg, nil}
  defp normalize_head(_), do: :skip

  # ── The verdict ──────────────────────────────────────────────────────────

  # A handler REACHES its gate when at least one NON-catch-all clause head
  # matches the payload. `:ok` coming back proves nothing: the catch-all returns
  # :ok too, which is exactly why this reads heads instead of return values.
  defp reaches?(clauses, payload) do
    Enum.any?(clauses, fn {pattern, guard} ->
      not catch_all?(pattern) and matches?(pattern, guard, payload)
    end)
  end

  # A bare variable (`_payload`, `payload`, `_`) matches every term; it is the
  # fall-through, not the gate.
  defp catch_all?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp catch_all?(_), do: false

  defp matches?(pattern, guard, payload) do
    left = if guard, do: {:when, [], [pattern, guard]}, else: pattern

    ast =
      {:case, [],
       [
         Macro.escape(payload),
         [
           do: [
             {:->, [], [[left], use_bound_vars(pattern)]},
             {:->, [], [[{:_, [], nil}], false]}
           ]
         ]
       ]}

    {result, _} = Code.eval_quoted(ast)
    result
  rescue
    e ->
      flunk("""
      could not evaluate a clause head as a pattern — the scan cannot report a verdict about
      it, and silently reading it as "no match" would be a guess:

        head:  #{Macro.to_string(pattern)}
        error: #{Exception.message(e)}
      """)
  end

  # Body of the matching clause: touch every variable the head bound so the
  # evaluated snippet raises no "unused variable" warnings, then answer `true`.
  defp use_bound_vars(pattern) do
    {_, vars} =
      Macro.prewalk(pattern, [], fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if String.starts_with?(Atom.to_string(name), "_"),
            do: {node, acc},
            else: {node, [{name, [], nil} | acc]}

        node, acc ->
          {node, acc}
      end)

    {:__block__, [],
     [
       {:=, [], [{:_bound, [], nil}, {:{}, [], Enum.uniq(vars)}]},
       true
     ]}
  end
end
