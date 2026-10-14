defmodule Barkpark.Content.WikilinkResolveTenancyTest do
  @moduledoc """
  A document link (`wikilink`) can carry any `docId` a host puts there (the
  canvas's toolbar `toggleMark("wikilink", { docId })`). Resolving it for a
  render reads only the rendering document's own dataset and workspace: a
  `docId` (or title) that names a paper in another workspace, another dataset,
  or nothing at all resolves to nothing, so it renders as an unresolved link and
  never shows another tenant's title. With no workspace at all, nothing resolves.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "production"

  setup do
    a = create_workspace!()
    pa = create_project!(a)
    b = create_workspace!()
    pb = create_project!(b)

    {:ok, _} = create_document_in!(a, pa, "paper", %{"_id" => "a-own", "title" => "A own"}, @ds)

    {:ok, _} =
      create_document_in!(b, pb, "paper", %{"_id" => "b-secret", "title" => "B secret"}, @ds)

    {:ok, _} =
      create_document_in!(
        a,
        pa,
        "paper",
        %{"_id" => "a-elsewhere", "title" => "A elsewhere"},
        "other"
      )

    {:ok, a: a, pa: pa}
  end

  defp link(doc_id),
    do: %{
      "type" => "wikilink",
      "target" => doc_id,
      "docId" => doc_id,
      "children" => [%{"type" => "text", "value" => doc_id}]
    }

  defp blocks(ids),
    do: [%{"id" => "p", "type" => "paragraph", "content" => Enum.map(ids, &link/1)}]

  test "only the rendering workspace's own paper resolves; foreign, other-dataset and missing ids do not",
       ctx do
    hits =
      Content.resolve_wikilinks_in_blocks(
        blocks(["a-own", "b-secret", "a-elsewhere", "no-such-doc"]),
        @ds,
        workspace_id: ctx.a.id,
        project_id: ctx.pa.id
      )

    assert %{title: "A own"} = hits[{:id, "a-own"}]
    refute Map.has_key?(hits, {:id, "b-secret"})
    refute Map.has_key?(hits, {:id, "a-elsewhere"})
    refute Map.has_key?(hits, {:id, "no-such-doc"})

    titles = hits |> Map.values() |> Enum.map(& &1.title)
    refute "B secret" in titles
    refute "A elsewhere" in titles
  end

  test "a foreign paper's title typed as the target does not resolve either", ctx do
    hits =
      Content.resolve_wikilinks_in_blocks(
        [
          %{
            "id" => "p",
            "type" => "paragraph",
            "content" => [%{"type" => "wikilink", "target" => "B secret", "children" => []}]
          }
        ],
        @ds,
        workspace_id: ctx.a.id,
        project_id: ctx.pa.id
      )

    assert hits == %{}
  end
end
