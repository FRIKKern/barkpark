defmodule BarkparkWeb.Integration.MediaFlatUploadProjectScopeTest do
  @moduledoc """
  The flat media WRITE path must never resolve its `dataset_id` from the DEFAULT
  project when the caller's token derived a NON-Default workspace.

  A token carries no project binding — `Auth.create_token/5` has no project
  argument. On the flat `/v1/media/:dataset/*` routes
  `Plugs.DeriveWorkspaceFromToken` assigns only `:current_workspace`, and
  `Plugs.AssignDefaultScope` DELIBERATELY declines to stamp the Default Project
  for a non-Default workspace, because pairing workspace A with a Default-owned
  project means (its moduledoc) "every scoped read matches zero rows, and every
  scoped write stamps a `project_id` belonging to another tenant".

  `ScopeHelpers.put_scope/3` drops a nil scope entirely, so `:project_id`
  reaches `Media.put_scope_attrs/2` ABSENT rather than nil — and the old
  `Keyword.get(opts, :project_id) || default_project_id()` fallback therefore
  fired and re-created exactly that cross-tenant pairing.

  ## Why this test is not vacuous

  BOTH projects own a dataset called "production". That collision is the whole
  point: if only the caller's project had one, the Default lookup would return
  nil, `dataset_id` would be nil anyway, and the assertion would pass on a
  broken fence. With the collision planted, a reader that substitutes the
  Default project resolves a REAL dataset row — the wrong tenant's — and the
  assertion catches it.

  This is the WRITE half of the family. It is the one that persists: a file
  stamped with a foreign `dataset_id` stays wrong after the code is fixed.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    # The DEFAULT scope, with a "production" dataset — the row a Default-project
    # fallback would wrongly resolve to.
    {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()
    {:ok, default_dataset} = Tenancy.get_or_create_dataset(default_proj.id, @dataset)

    # The CALLER's scope: a different workspace, its own project, and its OWN
    # dataset carrying the SAME slug.
    caller_ws = TenancyFixtures.create_workspace!()
    caller_proj = TenancyFixtures.create_project!(caller_ws)
    {:ok, caller_dataset} = Tenancy.get_or_create_dataset(caller_proj.id, @dataset)

    refute default_ws.id == caller_ws.id
    refute default_dataset.id == caller_dataset.id

    raw = "flat-upload-scope-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "flat upload scope",
        @dataset,
        ["read", "write"],
        caller_ws.id
      )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")

    %{
      conn: conn,
      caller_ws: caller_ws,
      caller_dataset: caller_dataset,
      default_dataset: default_dataset
    }
  end

  defp png_upload do
    tmp = Path.join(System.tmp_dir!(), "flat-upload-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, @png)
    %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}
  end

  test "a workspace-bound token's flat upload never carries the DEFAULT project's dataset_id",
       %{
         conn: conn,
         caller_ws: caller_ws,
         caller_dataset: caller_dataset,
         default_dataset: default_dataset
       } do
    resp = post(conn, ~p"/v1/media/#{@dataset}/upload", %{"file" => png_upload()})

    assert resp.status in [200, 201], "upload failed: #{resp.status} #{resp.resp_body}"

    body = Jason.decode!(resp.resp_body)
    id = get_in(body, ["result", "id"])
    assert is_binary(id), "no file id in upload response: #{resp.resp_body}"

    {:ok, file} = Media.get_file(id, workspace_id: caller_ws.id)

    # The write landed in the caller's workspace…
    assert file.workspace_id == caller_ws.id

    # …and THE ASSERTION THIS FILE EXISTS FOR: it must not have been stamped
    # with the Default project's dataset row. Before the fix, `project_id`
    # arrived absent, the `|| default_project_id()` fallback resolved
    # "production" inside the DEFAULT project, and this was
    # `default_dataset.id` — another tenant's row, persisted.
    refute file.dataset_id == default_dataset.id,
           "flat upload stamped the DEFAULT project's dataset_id (#{default_dataset.id}) " <>
             "onto a file owned by workspace #{caller_ws.id}"

    # Honouring an absent project means no dataset_id is resolved at all; the
    # caller's own dataset row is the only other acceptable answer.
    assert file.dataset_id in [nil, caller_dataset.id],
           "unexpected dataset_id #{inspect(file.dataset_id)} — expected nil or " <>
             "the caller's own #{caller_dataset.id}"
  end
end
