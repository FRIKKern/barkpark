defmodule BarkparkWeb.Plugs.RequireShareScopeItemExpandConfinementTest do
  @moduledoc """
  task-d5e8b90e08bd4d4e — an ITEM share link (`?share=<token>`) is confined to
  the ONE document it is bound to. `maybe_grant_item_token/4` assigned
  `:current_workspace` / `:current_project` / `:share_public` / `:share_access`
  but recorded the link's KIND nowhere, so `query_controller`'s `?expand=`
  (reference-walk) and `?resolve=tasks` (scope-wide task query) could not tell
  an item grant from a section grant — either param let a leaked item link
  read documents/tasks far outside the ONE bound doc.

  Fix: `maybe_grant_item_token/4` now assigns `:share_grant, :item` (the
  section-grant site assigns `:share_grant, :section`), and for an `:item`
  grant the plug strips `expand`/`resolve` from BOTH `conn.params` and
  `conn.query_params` before returning — the controller never sees either
  param on an item-granted request. This also discharges the row's original
  criterion #5 (the `?resolve=tasks` sibling of the `?expand=` defect).

  Every confinement case here is paired with a CONTROL proving the fix is
  narrow, not a general breakage:
    * a SECTION grant on the same scope still gets `?expand=` / `?resolve=tasks`
    * the item grant still reads its OWN bound doc normally with no param
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing, Tasks, Tenancy}
  alias Barkpark.Sharing.Links

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("item-expand-ws")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "item-expand-proj"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "linkpost",
          "title" => "Link Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "related", "type" => "reference", "refType" => "linkpost"}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "referenced-doc", "title" => "SECRET-REFERENCED-BODY"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("referenced-doc", "linkpost", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "linkpost",
        %{"_id" => "bound-doc", "title" => "Bound Doc", "related" => "referenced-doc"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("bound-doc", "linkpost", @dataset, scope)

    # The global `paper` schema (registered nil-workspace by the Bulldocs
    # plugin) is invisible to a WORKSPACE-SCOPED read: `schema_public?/3`
    # threads `[workspace_id:, project_id:]` into `get_schema/3`, whose
    # `scope_to_workspace_or_global/3` delegates to the FAIL-CLOSED
    # `scope_to_workspace/3` once a non-nil workspace_id is given — it does
    # NOT fall back to the nil-workspace global row. A workspace-scoped
    # `paper` schema (same shape the global one registers) makes the
    # `?resolve=tasks` route's `schema_public?` gate pass for THIS workspace.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    label = "item-confine-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "item-confine-task-#{System.unique_integer([:positive])}",
          "title" => "SECRET-TASK",
          "content" => %{"kind" => "task", "lifecycle_status" => "open", "labels" => [label]}
        },
        @dataset,
        scope
      )

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "bound-paper",
          "title" => "Bound Paper",
          "dataset" => @dataset,
          "blocks" => [%{"id" => "b1", "type" => "task-list", "query" => %{"label" => label}}],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        }),
        dataset: @dataset
      )

    %{conn: conn, ws: ws, proj: proj, label: label}
  end

  defp with_shares(env_string) do
    prior = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse(env_string))

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

    :ok
  end

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}"

  defp doc_path(ws, proj, type, id),
    do: "#{base(ws, proj)}/v1/data/doc/#{@dataset}/#{type}/#{id}"

  defp mint_item_link!(ws, proj, ref_type, ref_id) do
    {:ok, {raw, _link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: ref_type,
        ref_id: ref_id,
        access: "read"
      })

    raw
  end

  describe "?expand= on an item grant" do
    test "an item-linked doc's ?expand=related does NOT resolve the reference", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      raw = mint_item_link!(ws, proj, "linkpost", "bound-doc")

      result =
        conn
        |> get(doc_path(ws, proj, "linkpost", "bound-doc") <> "?share=#{raw}&expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["_id"] == "bound-doc"
      assert result["related"] == "referenced-doc"
      refute is_map(result["related"])
      refute Jason.encode!(result) =~ "SECRET-REFERENCED-BODY"
    end

    test "CONTROL: a SECTION grant on the same scope still gets its ?expand=", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

      result =
        conn
        |> get(doc_path(ws, proj, "linkpost", "bound-doc") <> "?expand=related")
        |> json_response(200)
        |> Map.fetch!("result")

      assert is_map(result["related"])
      assert result["related"]["_id"] == "referenced-doc"
      assert result["related"]["title"] == "SECRET-REFERENCED-BODY"
    end

    test "CONTROL: the item grant still reads its own bound doc normally", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      raw = mint_item_link!(ws, proj, "linkpost", "bound-doc")

      result =
        conn
        |> get(doc_path(ws, proj, "linkpost", "bound-doc") <> "?share=#{raw}")
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["_id"] == "bound-doc"
      assert result["title"] == "Bound Doc"
    end
  end

  describe "?resolve=tasks on an item grant" do
    test "an item-linked paper's ?resolve=tasks does NOT resolve the task query", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      raw = mint_item_link!(ws, proj, "paper", "bound-paper")

      result =
        conn
        |> get(doc_path(ws, proj, "paper", "bound-paper") <> "?share=#{raw}&resolve=tasks")
        |> json_response(200)
        |> Map.fetch!("result")

      [block] = result["blocks"]
      assert block["type"] == "task-list"
      assert Map.has_key?(block, "query")
      refute Map.has_key?(block, "snapshot")
      refute Jason.encode!(result) =~ "SECRET-TASK"
    end

    test "CONTROL: a SECTION grant on the same scope still gets ?resolve=tasks", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

      result =
        conn
        |> get(doc_path(ws, proj, "paper", "bound-paper") <> "?resolve=tasks")
        |> json_response(200)
        |> Map.fetch!("result")

      [block] = result["blocks"]
      assert block["type"] == "task-list"
      assert Map.has_key?(block, "snapshot")
    end
  end
end
