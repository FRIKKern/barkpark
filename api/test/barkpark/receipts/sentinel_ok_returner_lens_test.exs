defmodule Barkpark.Receipts.SentinelOkReturnerLensTest do
  @moduledoc """
  THE SENTINEL-:ok-RETURNER LENS (pds-bl-sentinel-ok-returner-population).

  The shape: a callee that performs a Repo WRITE and then returns a hard-coded
  bare `:ok` as its final expression — the write's outcome destroyed one frame
  below its caller, so no caller can ever report failure. Invisible to the
  Elixir receipt census by construction: it is not catch-all shaped and it is
  not an `ok: true` literal.

  THE LENS, STATED PRECISELY (its scope is its honesty):

    * corpus: every `.ex` under `lib/` of this app, parsed to AST with
      `Code.string_to_quoted/2` — no regex;
    * a function clause (`def`/`defp`) MATCHES when BOTH hold:
      - its body contains a call to `<Alias>.Repo.<write>/...` where write is
        one of insert/insert!/insert_all/update/update!/update_all/delete/
        delete!/delete_all;
      - the clause body's FINAL top-level expression is the literal atom `:ok`
        (a tail `:ok` inside a nested case/if arm does NOT match — a stated
        limitation, not an accident: a branch-tail sentinel needs branch-aware
        judgment this lens does not claim to make).
    * a callee that returns the WRITE RESULT does NOT match — that is the
      honest shape, and the negative control below pins that the lens can
      say NO.

  The population is PRINTED on every run and pinned to the committed baseline
  below, so a NEW arrival of the shape reds this test (an arrival tripwire,
  not a one-shot count). A site leaves or joins the baseline only by being
  PAID (return the write result), DECLARED in code, or adjudicated on the
  ledger — never by silently editing the baseline.
  """
  use ExUnit.Case, async: true

  @write_funs [
    :insert,
    :insert!,
    :insert_all,
    :update,
    :update!,
    :update_all,
    :delete,
    :delete!,
    :delete_all
  ]

  # The MEASURED population on origin/main the day this lens shipped — 19
  # sites, printed by the lens itself. The row's exemplar,
  # Accounts.revoke_user_session_token/1, is ABSENT because it was PAID
  # (PDS-D523: returns {:ok, count} with the idempotence contract in its
  # @doc). These 19 are BASELINED, not blessed: each is a named candidate for
  # the same pay-or-declare adjudication; what this pin buys today is that the
  # population can no longer GROW silently.
  @baseline [
    "lib/barkpark/accounts.ex:record_failed_login/1",
    "lib/barkpark/accounts.ex:reset_failed_logins/1",
    "lib/barkpark/auth.ex:touch_last_used/1",
    "lib/barkpark/chat_hosts/context.ex:mark_projected/1",
    "lib/barkpark/content/exemptions.ex:clear/2",
    "lib/barkpark/content/papers.ex:refresh_html_cache/3",
    "lib/barkpark/plugins/bootstrap.ex:stamp_scope/2",
    "lib/barkpark/pulse.ex:add_cost_nanos/1",
    "lib/barkpark/search/surface_configs.ex:seed_defaults!/0",
    "lib/barkpark/seeds/demo.ex:seed_schemas/1",
    "lib/barkpark/seeds/shared.ex:ensure_builtin_roles/0",
    "lib/barkpark/sync/cursor.ex:put/4",
    "lib/barkpark/sync/dead_letter.ex:mark_dead/3",
    "lib/barkpark/sync/push_conflict.ex:record/5",
    "lib/barkpark/sync/push_cursor.ex:bootstrap_if_absent/3",
    "lib/barkpark/sync/push_cursor.ex:put/4",
    "lib/barkpark/sync/push_doc_rev.ex:put/5",
    "lib/barkpark/tasks/edges.ex:remove_dep/3",
    "lib/barkpark/tenancy.ex:delete_workspace_audit_sinks/1"
  ]

  test "the sentinel-:ok-returner population across lib/ matches the adjudicated baseline" do
    population =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(&sentinel_sites/1)
      |> Enum.sort()

    IO.puts(
      "SENTINEL-:ok-RETURNER population (#{length(population)} site(s)):\n" <>
        ((population == [] && "  (none)") || Enum.map_join(population, "\n", &("  " <> &1)))
    )

    assert population == @baseline,
           "the sentinel-:ok-returner population moved. An arrival must be PAID " <>
             "(return the write result) or DECLARED in code; a departure leaves by the " <>
             "same door. Do not silently edit @baseline."
  end

  test "negative control: a callee that returns the write result does NOT match" do
    honest = """
    defmodule H do
      def revoke(q) do
        {n, _} = Repo.update_all(q, set: [revoked_at: now()])
        {:ok, n}
      end
    end
    """

    assert analyze_source(honest) == []
  end

  test "positive control: a write followed by a bare literal :ok DOES match" do
    guilty = """
    defmodule G do
      def revoke(q) do
        Repo.update_all(q, set: [revoked_at: now()])
        :ok
      end
    end
    """

    assert analyze_source(guilty) == ["G.revoke/1"]
  end

  test "scope honesty: a branch-tail :ok is stated OUT of scope and does not match" do
    branchy = """
    defmodule B do
      def revoke(q, flag) do
        Repo.update_all(q, set: [x: 1])
        if flag, do: :ok, else: :error
      end
    end
    """

    assert analyze_source(branchy) == []
  end

  # ── the lens itself ────────────────────────────────────────────────────────

  defp sentinel_sites(path) do
    case Code.string_to_quoted(File.read!(path), columns: false) do
      {:ok, ast} -> matches(ast) |> Enum.map(&"#{path}:#{&1}")
      {:error, _} -> []
    end
  end

  defp analyze_source(src) do
    {:ok, ast} = Code.string_to_quoted(src)
    matches(ast) |> Enum.map(fn fa -> module_name(ast) <> "." <> fa end)
  end

  defp module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, mods} | _]} = n, nil ->
          {n, Enum.map_join(mods, ".", &to_string/1)}

        n, acc ->
          {n, acc}
      end)

    name || "?"
  end

  defp matches(ast) do
    {_, sites} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [{:do, body} | _]]} = node, acc when kind in [:def, :defp] ->
          if repo_write?(body) and final_bare_ok?(body) do
            {node, [fn_id(head) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  defp fn_id({:when, _, [inner | _]}), do: fn_id(inner)
  defp fn_id({name, _, args}) when is_atom(name), do: "#{name}/#{length(List.wrap(args))}"
  defp fn_id(_), do: "?/?"

  defp repo_write?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, mods}, f]}, _, _} = node, acc ->
          {node, acc or (List.last(mods) == :Repo and f in @write_funs)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp final_bare_ok?({:__block__, _, exprs}), do: List.last(exprs) == :ok
  defp final_bare_ok?(:ok), do: true
  defp final_bare_ok?(_), do: false
end
