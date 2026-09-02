defmodule Barkpark.Media.Delivery.RetrieverWorkspaceScopeTest do
  @moduledoc """
  barkpark-sknf, media arm (task-d1b7b95fb5153311).

  `Retriever.asset_doc_join_query/3` used to call
  `Content.resolve_read_dataset_id/2` with a freshly built
  `[project_id: project_id]` list even though `workspace_id` was bound right
  beside it. That resolver only skips the seeded-Default fallback when it sees
  a `:workspace_id` KEY, so the guard was unreachable from this call site: a
  workspace-only read (the shape a flat `/v1/media/:dataset/search` with a
  token-derived workspace produces — `DeriveWorkspaceFromToken` sets the
  workspace, nothing sets the project) resolved the DEFAULT project's
  `dataset_id` and the join excluded this tenant's own asset docs.

  Blast radius is DEGRADED, not blank, and that is what these tests pin. The
  join's dataset filter is NULL-tolerant and the asset doc binds through a LEFT
  JOIN, so the blob row survived and only its METADATA arm (title / tags) was
  lost — media text search quietly fell back to filename-only. Every assertion
  below is POSITIVE (a row IS returned): an absence assertion here would pass
  vacuously against a bad fixture, since an empty fixture returns `[]` too.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Retriever
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"
  @config %{}

  # Run the built filter and return the matched blob ids. `raw: ""` keeps
  # `Synonyms.search_terms/4` out of the picture so the only thing under test
  # is the join's scope resolution.
  defp matched_ids(term, opts) do
    parsed = %{terms: [term], phrases: [], prefixes: [], raw: ""}

    case Retriever.build_text_filter(@dataset, parsed, @config, opts) do
      nil -> []
      q -> q |> exclude(:order_by) |> select([m], m.id) |> Repo.all()
    end
  end

  defp insert_asset_doc!(media_file_id, title, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id, "tags" => []}
      }
      |> Map.merge(scope)

    {:ok, doc} = %Document{} |> Document.changeset(attrs) |> Repo.insert()
    doc
  end

  setup do
    # The trap is only ARMED when the Default project owns a `production`
    # dataset row whose id differs from workspace A's. Assert that, or the
    # whole fixture is a no-op that would pass against the broken code.
    {_default_ws, default_project} = ensure_default_scope!()
    {:ok, default_ds} = Tenancy.get_or_create_dataset(default_project, @dataset)

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    {:ok, ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

    refute default_ds.id == ds_a.id,
           "FIXTURE NOT ARMED: workspace A resolved the SAME dataset row as the " <>
             "seeded Default project, so the Default fallback is indistinguishable " <>
             "from the correct resolution"

    token = "zqxmeta#{System.unique_integer([:positive])}"

    {:ok, file_a} =
      create_media_file_in!(ws_a, proj_a, %{dataset_id: ds_a.id}, @dataset)

    # Non-NULL dataset_id on the asset doc is load-bearing: a NULL would be
    # rescued by the join's `is_nil(d.dataset_id) and d.dataset == ^dataset`
    # arm and the bug would not reproduce.
    doc_a =
      insert_asset_doc!(file_a.id, "#{token} landscape", %{
        workspace_id: ws_a.id,
        project_id: proj_a.id,
        dataset_id: ds_a.id
      })

    refute is_nil(doc_a.dataset_id),
           "FIXTURE NOT ARMED: the asset doc has a NULL dataset_id, which the " <>
             "NULL-tolerant join arm rescues regardless of the resolver"

    %{ws_a: ws_a, proj_a: proj_a, file_a: file_a, token: token}
  end

  test "CONTROL — a workspace+project scoped read finds the asset doc's title",
       %{ws_a: ws_a, proj_a: proj_a, file_a: file_a, token: token} do
    ids = matched_ids(token, workspace_id: ws_a.id, project_id: proj_a.id)

    assert file_a.id in ids,
           "the metadata-matching row is not reachable even under the FULL scope — " <>
             "the fixture, not the resolver, is broken"
  end

  test "a workspace-only read (no project) still finds the asset doc's title",
       %{ws_a: ws_a, file_a: file_a, token: token} do
    ids = matched_ids(token, workspace_id: ws_a.id, project_id: nil)

    assert file_a.id in ids,
           "barkpark-sknf: asset_doc_join_query/3 dropped :workspace_id into " <>
             "resolve_read_dataset_id/2, so the resolver fell back to the seeded " <>
             "Default project's dataset_id and the join excluded workspace A's own " <>
             "asset doc — media metadata search degraded to filename-only for " <>
             "every token-derived workspace"
  end

  test "SEVERITY PIN — the filename arm keeps working under a workspace-only read",
       %{ws_a: ws_a, file_a: file_a} do
    ids = matched_ids(file_a.filename, workspace_id: ws_a.id, project_id: nil)

    assert file_a.id in ids,
           "the blob-side filename match is gone too — this defect is DEGRADED " <>
             "(metadata-only loss), not a blackout. If this fails, " <>
             "join_scope_dataset/3 was strict-ened and the shape changed"
  end

  test "NEVER-WORSE — an unscoped read still resolves the dataset authoritatively",
       %{file_a: file_a, token: token} do
    # No workspace at all: the resolver MUST keep its Default-project fallback
    # (barkpark-y9ee). Workspace A's doc is Default-invisible, so an unscoped
    # read must NOT pick it up via a legacy bare-string dataset filter — which
    # is exactly what an UNCONDITIONAL `workspace_id: nil` would cause.
    ids = matched_ids(token, workspace_id: nil, project_id: nil)

    refute file_a.id in ids,
           "the workspace key was forwarded UNCONDITIONALLY (as a nil value): the " <>
             "presence-keyed guard fired for the genuinely-unscoped caller, dropping " <>
             "it to the legacy `dataset` STRING and re-conflating same-named datasets " <>
             "across tenants (barkpark-y9ee)"
  end
end
