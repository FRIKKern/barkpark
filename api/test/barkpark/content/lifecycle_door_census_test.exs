defmodule Barkpark.Content.LifecycleDoorCensusTest do
  @moduledoc """
  Every caller of a lifecycle door in `api/lib` is classified here
  (task-500780ff96309744).

  `LiveWriteGate.check_seat/1` judges the seat in `opts[:caller_context]`, and
  when opts carry none it lets the write through (`Tenancy.Auth.publish_refused?/2`,
  its false arm). So a door caller that rebuilds opts from scope
  (`Keyword.take(opts, [:workspace_id, :project_id])`, `MediaFile.scope_opts/1`)
  drops the seat and the gate never sees it. `live_write_gate_census_test.exs`
  keys on `Document.changeset(` and cannot see these.

  The doors: `Content.publish_document/4`, `publish_built_draft/4`,
  `unpublish_document/4`, `delete_document/4`, `apply_mutations/3`, and any
  `update_all` on documents. A function that hands its own opts parameter to a
  door unchanged is a door too, so its callers are censused the same way.

  A caller is one of:

    * `:caller` - its opts carry the caller: they come from a builder that sets
      `:caller_context` (`@carriers`), or are the function's own opts parameter,
      passed on unchanged. Checked from the source; a function that also trims
      opts (`Keyword.take/drop/delete`) is not taken on trust.
    * `{:system, why}` - no caller seat drives the write.
    * `{:pending, task_id, why}` - drops `:caller_context` today; its task fixes it.
      Held to no check, so the fix's own PR stays green; flip it to `:caller`
      once the fix lands.

  An unclassified caller reds the first test; a `:caller` that stops carrying
  the caller reds the second.

  Scope, stated: a door caller is found by the door's name with a `Content.` (or
  same-module) call; a call through `apply/3` or a captured fun is not seen. The
  carrier check is per function, not per argument. The `update_all` census
  finds functions whose query names `Document` or `"documents"`.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  # The door modules themselves: their calls between doors are the door.
  @internal ~w(barkpark/content.ex barkpark/content/lifecycle.ex barkpark/content/mutations.ex)

  # {module, door} => index of the opts argument.
  @doors %{
    {"Content", :publish_document} => 3,
    {"Content", :publish_built_draft} => 3,
    {"Content", :unpublish_document} => 3,
    {"Content", :delete_document} => 3,
    {"Content", :apply_mutations} => 2,
    {"Lifecycle", :publish_document} => 3,
    {"Lifecycle", :publish_built_draft} => 3,
    {"Lifecycle", :unpublish_document} => 3,
    {"Lifecycle", :delete_document} => 3,
    {"Mutations", :apply_mutations} => 2
  }

  # Builders whose opts carry `:caller_context` (pinned by the last test), and a
  # literal `caller_context:` key.
  @carriers [:hook_opts, :scope_opts, :scope_opts_from_assigns, :resolve_write_scope]
  # Called by module name, only these count: `MediaFile.scope_opts/1` is scope
  # without the caller.
  @carrier_modules [:ScopeHelpers, :Shared]

  @masters "task-a6307f0d04cf513d"
  @share "task-e867294fdbcf6f55"
  @media_delete "task-166a84a8502afbc5"
  @task_verbs "task-8078ea8cff5bdef0"

  @census %{
    "barkpark/content/papers/value_writeback.ex maybe_propagate_publish/3 → publish_document" =>
      :caller,
    "barkpark/content/papers/value_writeback.ex writeback/6 → apply_mutations" => :caller,
    "barkpark/content/papers/value_writeback.ex writeback/6 → maybe_propagate_publish" => :caller,
    "barkpark/content/scheduled_publishes.ex execute/1 → publish_document" => :caller,
    "barkpark/media/storage/collections.ex create_folder/3 → apply_mutations" => :caller,
    "barkpark/plugins/media/assets.ex delete_for_blob/3 → delete_document" => :caller,
    "barkpark_web/controllers/legacy_controller.ex delete/2 → delete_document" => :caller,
    "barkpark_web/controllers/mutate_controller.ex mutate/2 → reader_checked" => :caller,
    "barkpark_web/controllers/mutate_controller.ex reader_checked/4 → apply_mutations" => :caller,
    "barkpark_web/controllers/v1/media_collections_controller.ex create/2 → create_folder" =>
      :caller,
    "barkpark_web/live/studio/studio_live/handlers/delete.ex delete_open_doc/3 → delete_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/handlers/doc.ex publish_open_doc/1 → publish_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/handlers/doc.ex publish_tag_under_name/4 → publish_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/handlers/paper.ex valueref_writeback/2 → writeback" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared.ex bulk_action/2 → publish_document" => :caller,
    "barkpark_web/live/studio/studio_live/shared.ex bulk_action/2 → unpublish_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared.ex do_unpublish/1 → unpublish_open_doc" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared.ex unpublish_open_doc/4 → unpublish_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared/paper.ex ensure_label_registered/2 → register_label" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared/paper.ex paper_publish/1 → publish_document" =>
      :caller,
    "barkpark_web/live/studio/studio_live/shared/paper.ex register_label/4 → publish_document" =>
      :caller,
    # Pending: each drops :caller_context today.
    "barkpark/plugins/bulldocs/masters.ex save_master/4 → publish_document" =>
      {:pending, @masters, "publishes with a scope rebuilt from opts"},
    "barkpark/media/storage/share.ex write_share_link/4 → publish_document" =>
      {:pending, @share, "write_opts/1 keeps scope only"},
    "barkpark/media.ex delete_asset_doc/1 → delete_for_blob" =>
      {:pending, @media_delete, "MediaFile.scope_opts/1 carries no caller"},
    "barkpark/plugins/media.ex after_media_delete/1 → delete_for_blob" =>
      {:pending, @media_delete, "calls with no opts"},
    # No caller seat.
    "barkpark/media/sanity_image_asset_doc.ex write/4 → apply_mutations" =>
      {:system, "derived: the sanityImageAsset doc a saved image ref points at"},
    "barkpark/sync/applier.ex apply_upsert/4 → apply_mutations" =>
      {:system, "Sync worker replays another server's listen stream"},
    "barkpark/sync/applier.ex apply_delete/4 → delete_document" =>
      {:system, "Sync worker replays another server's listen stream"},
    "barkpark/tenancy.ex delete_workspace_documents/1 → delete_document" =>
      {:system, "workspace deletion, behind its own admin check"},
    "barkpark/plugins/onixedit/mix_tasks/onix.import.ex handle_withdrawal/3 → delete_document" =>
      {:system, "mix task"},
    "mix/tasks/barkpark.bench.write_path.ex run/1 → run_mode" => {:system, "mix task"},
    "mix/tasks/barkpark.bench.write_path.ex run/1 → seed_brands!" => {:system, "mix task"},
    "mix/tasks/barkpark.bench.write_path.ex run_mode/7 → apply_mutations" =>
      {:system, "mix task"},
    "mix/tasks/barkpark.bench.write_path.ex seed_brands!/1 → apply_mutations" =>
      {:system, "mix task"}
  }

  @update_all %{
    "barkpark/content/papers/block_ops.ex fenced_paper_update/4" =>
      {:gated, "LiveWriteGate.check/2 before the write"},
    "barkpark/content/writer.ex fenced_update/3" =>
      {:drafts_only, "every write target goes through DraftId.draft_id/1"},
    "barkpark/content/reseal.ex upgrade_one/1" =>
      {:system, "operator reseal of encrypted fields"},
    "barkpark/content/reseal.ex reseal_one/1" => {:system, "operator reseal of encrypted fields"},
    "barkpark/content/sessions.ex append_event/5" =>
      {:system, "append-only type:session event trail, no draft layer"},
    "barkpark/content/sessions.ex touch_conversation/5" =>
      {:system, "append-only type:session event trail, no draft layer"},
    "barkpark/cycle_fleet.ex materialize_release_paper/1" => {:system, "cycle fleet ledger"},
    "barkpark/cycle_fleet.ex insert_candidate_revision/2" => {:system, "cycle fleet ledger"},
    "barkpark/cycle_fleet.ex restore_release_document_in_scope/4" =>
      {:system, "cycle fleet ledger"},
    "barkpark/tasks/internal.ex admitted_fenced_content_write/4" =>
      {:pending, @task_verbs, "/v1/tasks verbs write live task rows in place"}
  }

  setup_all do
    texts =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          into: %{},
          do: {path, File.read!(path)}

    callers = door_callers(texts)
    %{callers: callers, update_all: update_all_writers(texts)}
  end

  test "every lifecycle-door caller is classified", %{callers: callers} do
    unclassified = Map.keys(callers) -- Map.keys(@census)

    assert unclassified == [],
           "these call a lifecycle door but are not in @census: #{inspect(unclassified)}. " <>
             "Pass the caller's opts (with :caller_context) and mark it :caller, or say " <>
             "why no caller seat drives the write."
  end

  test "every :caller still carries the caller", %{callers: callers} do
    dropped = for {key, :caller} <- @census, Map.get(callers, key) == :drops, do: key

    assert dropped == [],
           "these no longer pass the caller's opts to the door: #{inspect(dropped)}. " <>
             "Without :caller_context, LiveWriteGate.check_seat/1 lets the write through."
  end

  test "every classified caller still exists", %{callers: callers} do
    gone =
      for {key, class} <- @census, not pending?(class), not Map.has_key?(callers, key), do: key

    assert gone == []
  end

  test "every update_all on documents is classified", %{update_all: found} do
    assert found -- Map.keys(@update_all) == []

    gone = for {key, class} <- @update_all, not pending?(class), key not in found, do: key
    assert gone == []

    for {key, {:gated, _}} <- @update_all do
      [path | _] = String.split(key, " ")
      assert File.read!(Path.join(@lib, path)) =~ "LiveWriteGate.", key
    end
  end

  test "the carriers set :caller_context" do
    assert Keyword.has_key?(
             BarkparkWeb.ScopeHelpers.scope_opts_from_assigns(%{}),
             :caller_context
           )

    assert calls?(fun_body("barkpark_web/live/studio/studio_live/shared.ex", :hook_opts), [
             :scope_opts
           ])

    assert calls?(
             fun_body("barkpark_web/controllers/mutate_controller.ex", :resolve_write_scope),
             [:scope_opts]
           )
  end

  defp pending?({:pending, _, _}), do: true
  defp pending?(_), do: false

  # key => :carries | :drops. A function that forwards its opts parameter to a
  # door becomes a door, until no new one appears. Only files that name a door
  # are parsed.
  defp door_callers(texts) do
    Enum.reduce_while(1..10, {@doors, %{}, %{}}, fn _, {doors, _, asts} ->
      names = doors |> Map.keys() |> Enum.map(&"#{elem(&1, 1)}(") |> Enum.uniq()

      asts =
        for {path, text} <- texts,
            rel = Path.relative_to(path, @lib),
            rel not in @internal,
            Enum.any?(names, &String.contains?(text, &1)),
            into: asts,
            do: {rel, Map.get_lazy(asts, rel, fn -> parse(text) end)}

      {doors2, callers} = scan(asts, doors)

      if map_size(doors2) == map_size(doors),
        do: {:halt, callers},
        else: {:cont, {doors2, callers, asts}}
    end)
  end

  defp scan(asts, doors) do
    for {rel, {mod, ast}} <- asts,
        {name, params, body} <- defs(ast),
        {key, args} <- door_calls(body, mod, name, doors),
        reduce: {doors, %{}} do
      {doors, callers} ->
        arg = Enum.at(args, doors[key])
        fwd = arg && forwarded(arg, params, body)
        doors = if fwd, do: Map.put_new(doors, {mod, name}, fwd), else: doors
        carries? = arg != nil and calls?(body, @carriers) and not trims?(body)
        v = if fwd != nil or carries?, do: :carries, else: :drops
        k = "#{rel} #{name}/#{length(params)} → #{elem(key, 1)}"
        {doors, Map.update(callers, k, v, &if(:drops in [&1, v], do: :drops, else: :carries))}
    end
  end

  # Calls one of `funs`, or sets a `caller_context:` key.
  defp calls?(ast, funs) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        _, true ->
          {nil, true}

        {:caller_context, _} = n, _ ->
          {n, true}

        {{:., _, [{:__aliases__, _, parts}, f]}, _, args} = n, _ when is_list(args) ->
          {n, f in funs and List.last(parts) in @carrier_modules}

        {f, _, args} = n, _ when is_atom(f) and is_list(args) ->
          {n, f in funs}

        n, acc ->
          {n, acc}
      end)

    hit
  end

  # `Keyword.take/2` and friends rebuild opts and can drop the caller; a
  # function that uses one is not taken on trust.
  defp trims?(body) do
    {_, hit} =
      Macro.prewalk(body, false, fn
        _, true ->
          {nil, true}

        {{:., _, [{:__aliases__, _, [:Keyword]}, f]}, _, _} = n, _ ->
          {n, f in [:take, :drop, :delete]}

        n, acc ->
          {n, acc}
      end)

    hit
  end

  defp door_calls(body, mod, name, doors) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, parts}, f]}, _, args} = c, acc when is_list(args) ->
          key = {to_string(List.last(parts)), f}
          {c, if(Map.has_key?(doors, key), do: [{key, args} | acc], else: acc)}

        {f, _, args} = c, acc when is_atom(f) and is_list(args) ->
          key = {mod, f}
          {c, if(Map.has_key?(doors, key) and f != name, do: [{key, args} | acc], else: acc)}

        n, acc ->
          {n, acc}
      end)

    found
  end

  # The index of the parameter passed on unchanged (`opts` or `[k: v] ++ opts`),
  # or nil when opts are built here or the parameter is rebound first.
  defp forwarded(arg, params, body) do
    var =
      case arg do
        {v, _, c} when is_atom(v) and is_atom(c) -> v
        {:++, _, [_, {v, _, c}]} when is_atom(v) and is_atom(c) -> v
        _ -> nil
      end

    idx = var && Enum.find_index(params, &(param_name(&1) == var))
    if idx != nil and not rebinds?(body, var), do: idx
  end

  defp param_name({:\\, _, [p, _]}), do: param_name(p)
  defp param_name({v, _, c}) when is_atom(v) and is_atom(c), do: v
  defp param_name(_), do: nil

  defp rebinds?(body, var) do
    {_, hit} =
      Macro.prewalk(body, false, fn
        {:=, _, [{^var, _, c}, _]} = n, _ when is_atom(c) -> {n, true}
        n, acc -> {n, acc}
      end)

    hit
  end

  # An update_all whose query names Document or "documents", or is a variable
  # in a function that does.
  defp update_all_writers(texts) do
    for {path, text} <- texts,
        String.contains?(text, "update_all"),
        {_mod, ast} = parse(text),
        {name, params, body} <- defs(ast),
        update_all_on_documents?(body),
        uniq: true,
        do: "#{Path.relative_to(path, @lib)} #{name}/#{length(params)}"
  end

  defp update_all_on_documents?(body) do
    {_, queries} =
      Macro.prewalk(body, [], fn
        {{:., _, [_, :update_all]}, _, [q | _]} = n, acc -> {n, [q | acc]}
        {:|>, _, [q, {{:., _, [_, :update_all]}, _, _}]} = n, acc -> {n, [q | acc]}
        n, acc -> {n, acc}
      end)

    Enum.any?(queries, fn
      {v, _, c} when is_atom(v) and is_atom(c) -> names_documents?(body)
      q -> names_documents?(q)
    end)
  end

  defp names_documents?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        _, true -> {nil, true}
        {:__aliases__, _, parts} = n, _ -> {n, List.last(parts) == :Document}
        "documents" = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    hit
  end

  defp fun_body(rel, fun) do
    {_mod, ast} = parse(File.read!(Path.join(@lib, rel)))
    for {^fun, _, b} <- defs(ast), do: b
  end

  defp parse(text) do
    {:ok, ast} = Code.string_to_quoted(text)

    mod =
      case ast do
        {:defmodule, _, [{:__aliases__, _, parts} | _]} -> to_string(List.last(parts))
        _ -> nil
      end

    {mod, ast}
  end

  defp defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head | body]} = n, acc when kind in [:def, :defp] ->
          {name, params} =
            case head do
              {:when, _, [{nm, _, p} | _]} -> {nm, p || []}
              {nm, _, p} -> {nm, p || []}
            end

          {n, [{name, params, body} | acc]}

        n, acc ->
          {n, acc}
      end)

    acc
  end
end
