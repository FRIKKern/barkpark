defmodule BarkparkWeb.QueryCountsDatasetIdFenceTest do
  @moduledoc """
  `QueryController.scope_counts_to_dataset/3` (query_controller.ex) — the
  `d.dataset_id == ^id or (is_nil(d.dataset_id) and d.dataset == ^dataset)`
  discriminator behind `GET /v1/data/counts/:dataset`.

  ## What actually guards this read (task-cb44d1e29c44bda5, criterion 0)

  The clause has exactly ONE caller chain in the code:

      counts/2  ->  published_type_counts/2  ->  scope_counts_to_dataset/3

  and `published_type_counts/2` pipes through the fail-CLOSED
  `Content.Scope.scope_to_workspace/3`, never its permissive
  `scope_to_workspace_or_global/3` sibling. So the tenancy fence here is the
  workspace/project filter, and it holds on its own. That is NOT what this
  clause does.

  What the clause does is make `dataset_id` AUTHORITATIVE and demote the
  dataset STRING to a fallback for rows the tenancy backfill never stamped.
  Dropping `is_nil(d.dataset_id) and` turns the disjunct into a bare
  name match, so a row stamped with ANOTHER dataset's id is counted purely
  because its `dataset` string reads the same.

  ## Why the fixture uses the SCOPED route

  The clause is reached only when `Content.resolve_read_dataset_id/2` returns a
  binary id, which needs a `:project_id` in `ScopeHelpers.scope_opts/1`. On the
  FLAT route a token-derived non-Default workspace is left project-less by
  `Plugs.AssignDefaultScope` (deliberately — see its moduledoc), so the resolver
  returns nil and the ELSE arm's plain string match runs instead. The scoped
  mirror `/w/:ws/p/:project/v1/data/counts/:dataset` resolves a real project, so
  it is the shape that actually exercises line 413.

  Three rows, all in the SAME workspace+project, so the workspace/project
  filter cannot stand in for the clause under test:

    * `own-*`     — stamped with THIS project's dataset id  (control: counted)
    * `legacy-*`  — `dataset_id IS NULL`, string match      (control: counted,
                    proves the string disjunct is live, not dead code)
    * `foreign-*` — stamped with a SIBLING project's dataset id, same string
                    (the subject: must NOT be counted)

  With the clause intact the census is 2. Dropping `is_nil(d.dataset_id) and`
  makes it 3.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Content.Document

  setup do
    u = System.unique_integer([:positive])
    dataset = "qc_counts_fence_ds_#{u}"

    {:ok, ws} = Tenancy.create_workspace(%{slug: "qcf-ws-#{u}", name: "QCF WS #{u}"})
    {:ok, proj_one} = Tenancy.create_project(ws, %{slug: "qcf-p1-#{u}", name: "P1"})
    {:ok, proj_two} = Tenancy.create_project(ws, %{slug: "qcf-p2-#{u}", name: "P2"})

    scope_one = [workspace_id: ws.id, project_id: proj_one.id]
    scope_two = [workspace_id: ws.id, project_id: proj_two.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        dataset
      )

    own = "own-#{u}"
    legacy = "legacy-#{u}"
    foreign = "foreign-#{u}"

    # Writing through the normal path under EACH project get_or_creates that
    # project's own dataset row — the two ids this test plays off each other.
    publish(scope_two, dataset, "seed-#{u}")
    publish(scope_one, dataset, own)
    publish(scope_one, dataset, legacy)
    publish(scope_one, dataset, foreign)

    foreign_ds_id = Tenancy.get_dataset(proj_two.id, dataset).id
    own_ds_id = Tenancy.get_dataset(proj_one.id, dataset).id
    refute foreign_ds_id == own_ds_id

    # The only way a test can manufacture the two off-normal row shapes: write
    # through the real path, then restamp. `legacy` becomes the unstamped
    # backfill leftover; `foreign` keeps its proj_one tenancy but carries
    # proj_two's dataset id.
    stamp(legacy, nil)
    stamp(foreign, foreign_ds_id)

    raw = "qcf-token-#{u}"
    {:ok, _} = Auth.create_token(raw, "QCF token", dataset, ["read"], ws.id)

    {:ok,
     dataset: dataset, ws: ws, proj_one: proj_one, proj_two: proj_two, legacy: legacy, raw: raw}
  end

  defp publish(scope, dataset, id) do
    {:ok, _} =
      Content.create_document("post", %{"_id" => id, "title" => id}, dataset, scope)

    {:ok, _} = Content.publish_document(id, "post", dataset, scope)
  end

  defp stamp(doc_id, dataset_id) do
    {n, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^doc_id),
        set: [dataset_id: dataset_id]
      )

    assert n >= 1, "restamp matched no row for #{doc_id} — the fixture never wrote it"
  end

  defp own_ds_id(proj, dataset), do: Tenancy.get_dataset(proj.id, dataset).id

  defp rename_dataset_string(doc_id, dataset) do
    Repo.update_all(from(d in Document, where: d.doc_id == ^doc_id), set: [dataset: dataset])
  end

  defp counts(conn, raw, ws, proj, dataset) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
    |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/data/counts/#{dataset}")
    |> json_response(200)
  end

  describe "the dataset_id fence on GET /w/:ws/p/:project/v1/data/counts/:dataset" do
    test "a row stamped with a SIBLING project's dataset id is not counted by its name",
         %{conn: conn, raw: raw, ws: ws, proj_one: proj_one, dataset: dataset} do
      body = counts(conn, raw, ws, proj_one, dataset)

      assert body["ok"] == true
      assert body["dataset"] == dataset

      # own + legacy = 2. The foreign-stamped row makes it 3 the moment
      # `is_nil(d.dataset_id) and` is dropped from the disjunct.
      assert body["counts"] == %{"post" => 2}
    end

    test "CONTROL: the unstamped legacy row IS counted, so the string disjunct is live",
         %{conn: conn, raw: raw, ws: ws, proj_one: proj_one, dataset: dataset, legacy: legacy} do
      assert counts(conn, raw, ws, proj_one, dataset)["counts"]["post"] == 2

      # Restamping the legacy row with THIS project's own id must leave the
      # census unchanged — it was the string disjunct, not an id match, that
      # carried it a moment ago. Blanking its string instead drops it to 1,
      # which is what makes the disjunct observable rather than assumed.
      stamp(legacy, own_ds_id(proj_one, dataset))
      assert counts(conn, raw, ws, proj_one, dataset)["counts"]["post"] == 2

      stamp(legacy, nil)
      rename_dataset_string(legacy, dataset <> "_elsewhere")
      assert counts(conn, raw, ws, proj_one, dataset)["counts"]["post"] == 1
    end

    test "CONTROL: the sibling project sees its own stamped row, so the rows exist at all",
         %{conn: conn, raw: raw, ws: ws, proj_two: proj_two, dataset: dataset} do
      body = counts(conn, raw, ws, proj_two, dataset)

      # proj_two holds only its seed row: the foreign-STAMPED doc is physically
      # in proj_one, so the workspace/project filter (not the clause under test)
      # keeps it out here. Proves the absence above is a fence, not an empty
      # query against a dataset nobody wrote to.
      assert body["counts"] == %{"post" => 1}
    end
  end
end
