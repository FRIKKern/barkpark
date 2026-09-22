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

  # ── THE PROJECT RUNG (task-96d8720de593d82a) ───────────────────────────────
  #
  # `join_scope_workspace/3`'s is_binary/is_binary clause stacks TWO rungs in
  # one parenthesis:
  #
  #     is_nil(d.workspace_id) or
  #       (d.workspace_id == ^workspace_id and
  #          (is_nil(d.project_id) or d.project_id == ^project_id))
  #
  # Every test ABOVE drives the DATASET resolution and asserts POSITIVELY about
  # workspace A's own row, so none of them stands on the wrong side of the inner
  # parenthesis. Appending `or not is_nil(d.project_id)` to it — making it
  # unconditionally true while leaving the workspace rung byte-identical — left
  # all 366 media-fence tests green. The filename was the false reassurance: the
  # function is NOT dead (dropping it entirely reds two tests), the PROJECT RUNG
  # specifically had nothing occupying it.
  test "PROJECT RUNG — a SIBLING PROJECT's asset doc inside the caller's OWN workspace never joins",
       %{ws_a: ws_a, proj_a: proj_a} do
    proj_foreign = create_project!(ws_a)
    {:ok, ds_foreign} = Tenancy.get_or_create_dataset(proj_foreign, @dataset)

    token = "zqxrung#{System.unique_integer([:positive])}"

    {:ok, file_foreign} =
      create_media_file_in!(ws_a, proj_foreign, %{dataset_id: ds_foreign.id}, @dataset)

    # dataset_id NULL is LOAD-BEARING in the opposite direction from the setup
    # above: a STAMPED foreign dataset_id is refused by `join_scope_dataset/3`
    # before the workspace envelope is ever consulted, so the project rung would
    # again never be the discriminator (the assets_scope_test shape,
    # task-7faee37433ed92be). NULL + a stamped `dataset` STRING is what a
    # projectless write actually produces and it sails through the join's
    # NULL-tolerant leg.
    doc_foreign =
      insert_asset_doc!(file_foreign.id, "#{token} skyline", %{
        workspace_id: ws_a.id,
        project_id: proj_foreign.id,
        dataset_id: nil
      })

    assert is_nil(doc_foreign.dataset_id),
           "FIXTURE NOT ARMED: a stamped dataset_id is refused by join_scope_dataset/3 " <>
             "first, so the project rung is not the discriminator"

    assert doc_foreign.workspace_id == ws_a.id,
           "FIXTURE NOT ARMED: the foreign doc must share the caller's workspace, or the " <>
             "WORKSPACE rung is the excluder and the project rung stays untested"

    refute doc_foreign.project_id == proj_a.id

    # ARMED — with the project dropped, `join_scope_workspace/3` takes its
    # 2-arg clause, which has NO project rung, and the very same doc joins. So
    # everything except the project rung admits this row. The blob itself
    # carries no text match (its filename is `fixture-N.png`), so its id can
    # only arrive through the joined doc's title.
    assert file_foreign.id in matched_ids(token, workspace_id: ws_a.id, project_id: nil),
           "FIXTURE NOT ARMED: the foreign asset doc does not join even with the project " <>
             "dropped, so its absence below proves nothing about the project rung"

    refute file_foreign.id in matched_ids(token, workspace_id: ws_a.id, project_id: proj_a.id),
           "CROSS-PROJECT METADATA LEAK: a SIBLING PROJECT's mediaAsset title matched in " <>
             "a read scoped to project A inside the same workspace. Only the project rung " <>
             "of join_scope_workspace/3 can refuse that row — the workspace rung admits it " <>
             "by construction and join_scope_dataset/3 admits it on its NULL leg."
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
