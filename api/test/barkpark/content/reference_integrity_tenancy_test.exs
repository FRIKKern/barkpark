defmodule Barkpark.Content.ReferenceIntegrityTenancyTest do
  @moduledoc """
  task-f758cabf3a936e5e — the delete reference guard reads only the deleting
  caller's tenant. A document in workspace B that references an id which also
  exists in workspace A must neither block A's delete nor appear in A's 409
  referrer list (that list would disclose B's ids and types). With no
  workspace at all, the scan reads nothing.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.ReferenceIntegrity

  @ds "production"

  setup do
    a = create_workspace!()
    pa = create_project!(a)
    b = create_workspace!()
    pb = create_project!(b)

    {:ok, _} = create_document_in!(a, pa, "author", %{"_id" => "ann", "title" => "Ann"}, @ds)

    {:ok, _} =
      create_document_in!(b, pb, "author", %{"_id" => "ann", "title" => "Other Ann"}, @ds)

    {:ok, _} =
      create_document_in!(
        b,
        pb,
        "post",
        %{"_id" => "b-post", "title" => "B", "author" => %{"_ref" => "ann"}},
        @ds
      )

    {:ok, a: a, pa: pa, b: b, pb: pb}
  end

  defp delete(id, ws, proj),
    do:
      Content.apply_mutations(
        [%{"delete" => %{"id" => id, "type" => "author"}}],
        @ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

  test "a referrer in workspace B neither blocks nor appears in workspace A's delete", ctx do
    assert ReferenceIntegrity.referrers("ann", @ds, workspace_id: ctx.a.id, project_id: ctx.pa.id) ==
             []

    assert {:ok, _} = delete("ann", ctx.a, ctx.pa)
  end

  test "the same referrer still blocks the delete inside its own workspace", ctx do
    assert [%{id: "drafts.b-post", type: "post"}] =
             ReferenceIntegrity.referrers("ann", @ds,
               workspace_id: ctx.b.id,
               project_id: ctx.pb.id
             )

    assert {:error, {:document_referenced, "ann", [%{id: "drafts.b-post"}]}} =
             delete("ann", ctx.b, ctx.pb)
  end

  test "with no workspace the scan reads nothing" do
    assert ReferenceIntegrity.referrers("ann", @ds, []) == []
  end
end
