defmodule Barkpark.Content.FlatWriteScopeLeakTest do
  @moduledoc """
  Cross-tenant mass-assignment guard on the flat (unscoped) content write path.

  A flat/back-compat write carries no server scope opts, so the tenant is
  resolved to the seeded Default. A malicious client that smuggles a foreign
  `workspace_id` into the write attrs must NOT be able to stamp its document
  into another tenant — the client scope key is dropped and the write falls
  through to the Default scope (`Content.WriteScope.put_scope_attrs/2`).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @dataset "test"
  @type_name "post"

  test "a flat write carrying a foreign workspace_id lands in the Default scope" do
    {default_ws, default_proj} = ensure_default_scope!()
    foreign = create_workspace!()

    # A `content`-shaped payload (from_envelope passes it through untouched), so
    # the smuggled top-level workspace_id reaches put_scope_attrs — the exact
    # flat-route mass-assignment vector.
    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => "flat-leak",
          "content" => %{"title" => "x"},
          "workspace_id" => foreign.id,
          "project_id" => Ecto.UUID.generate()
        },
        @dataset,
        []
      )

    assert doc.workspace_id == default_ws.id
    assert doc.project_id == default_proj.id
    refute doc.workspace_id == foreign.id
  end

  test "an explicit scope still wins over a smuggled foreign workspace_id" do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    foreign = create_workspace!()

    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => "scoped-no-leak",
          "content" => %{"title" => "x"},
          "workspace_id" => foreign.id
        },
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    assert doc.workspace_id == ws_a.id
    refute doc.workspace_id == foreign.id
  end
end
