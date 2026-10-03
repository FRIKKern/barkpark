defmodule BarkparkWeb.MetaTenantScopeTest do
  @moduledoc """
  task-ca20672312df9ce3 — `GET /v1/meta` is the no-auth SDK handshake. Its pipeline
  (`:api_unlimited`) assigns no tenant scope, so `MetaController.index/2` read
  the schema catalog with no tenant. With no `?dataset`,
  `Content.schema_hash_for_all_datasets/0` grouped EVERY tenant's schemas by
  dataset, so an anonymous caller received the name of every dataset on the
  instance, any workspace's (plus a hash that moved on their schema edits).

  The `?dataset=<name>` arm was already Default-confined: `scope_to_dataset`
  resolves the dataset id inside the Default project. It is pinned here so the
  scope change cannot regress it. Every other anonymous flat read resolves to
  the Default workspace (`AssignDefaultScope`); the dataset map now does too.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}

  setup do
    other_ws = create_workspace!("meta-other")
    other = [workspace_id: other_ws.id, project_id: create_project!(other_ws, "meta-p").id]

    default = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    {:ok, _} =
      Content.upsert_schema(%{"name" => "post", "title" => "Post"}, "meta-default-ds", default)

    {:ok, _} =
      Content.upsert_schema(%{"name" => "post", "title" => "Post"}, "acme-merger-2027", other)

    {:ok, _} =
      Content.upsert_schema(%{"name" => "post", "title" => "Post"}, "meta-shared-ds", default)

    %{other: other}
  end

  defp meta(qs \\ ""), do: scoped_conn() |> get("/v1/meta" <> qs) |> json_response(200)

  test "ANONYMOUS: the dataset map lists only the Default tenant's datasets" do
    hashes = meta()["currentDatasetSchemaHash"]

    assert Map.has_key?(hashes, "meta-default-ds"), "CONTROL: Default's own dataset is listed"
    refute Map.has_key?(hashes, "acme-merger-2027")
  end

  test "PIN: a ?dataset hash does not move when another workspace edits that dataset",
       %{other: other} do
    before = meta("?dataset=meta-shared-ds")["currentDatasetSchemaHash"]

    {:ok, _} =
      Content.upsert_schema(%{"name" => "page", "title" => "Page"}, "meta-shared-ds", other)

    assert meta("?dataset=meta-shared-ds")["currentDatasetSchemaHash"] == before
  end
end
