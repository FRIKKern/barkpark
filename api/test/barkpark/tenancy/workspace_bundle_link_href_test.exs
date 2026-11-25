defmodule Barkpark.Tenancy.WorkspaceBundleLinkHrefTest do
  @moduledoc """
  task-9d0496cb3f369ed1 (#28393 review): a bundle import writes rows by raw
  COPY, past the Writer's `LinkHrefFence`, so a bundle stored a link whose
  address was `javascript:`. The import now strips such an address, in
  documents and revisions, keeps it as `refused_<key>`, and names each one
  in its stats.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, LinkHrefFence, Revision}
  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.LinkHrefCheck

  defp body(def) do
    [
      %{
        "_type" => "block",
        "_key" => "b1",
        "style" => "normal",
        "markDefs" => [Map.put(def, "_key", "m1")],
        "children" => [%{"_type" => "span", "_key" => "s1", "text" => "go", "marks" => ["m1"]}]
      }
    ]
  end

  defp link(href), do: body(%{"_type" => "link", "href" => href})

  defp put_body!(queryable, id, body) do
    {1, _} =
      Repo.update_all(from(r in queryable, where: r.id == ^id),
        set: [content: %{"title" => "fixture doc", "body" => body}]
      )
  end

  defp def_of(%{"body" => [%{"markDefs" => [def]}]}), do: def
  defp def_of(queryable, id), do: def_of(Repo.get!(queryable, id).content)

  setup do
    ws = create_workspace!("lhref-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    attrs = %{"doc_id" => "lh1", "body" => link("https://ok.example")}
    {:ok, doc} = create_document_in!(ws, proj, "post", attrs)
    %{ws: ws, proj: proj, doc: doc}
  end

  # The revision a restore would put back, holding the document's content.
  defp revision!(ws, doc) do
    stored = Repo.get!(Document, doc.id)

    Repo.insert!(%Revision{
      doc_id: String.replace_prefix(stored.doc_id, "drafts.", ""),
      type: stored.type,
      dataset: stored.dataset,
      title: stored.title,
      status: stored.status,
      action: "update",
      content: stored.content,
      document_id: stored.id,
      workspace_id: ws.id,
      project_id: stored.project_id,
      dataset_id: stored.dataset_id
    })
  end

  test "a document's javascript: link is stripped, kept as refused_href and named",
       %{ws: ws, doc: doc} do
    put_body!(Document, doc.id, link("javascript:alert(1)"))
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    put_body!(Document, doc.id, link("https://ok.example"))

    {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    assert def_of(Document, doc.id) == %{
             "_type" => "link",
             "_key" => "m1",
             "refused_href" => "javascript:alert(1)"
           }

    assert stats.refused_links == [
             %{
               table: "documents",
               doc_id: doc.doc_id,
               path: "/body/0/markDefs/0/href",
               href: "javascript:alert(1)"
             }
           ]
  end

  test "a revision's is stripped too, and a restore of it stores no javascript: link",
       %{ws: ws, proj: proj, doc: doc} do
    put_body!(Document, doc.id, link("javascript:x"))
    rev = revision!(ws, doc)
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    assert %{"refused_href" => "javascript:x"} = def_of(Revision, rev.id)
    refute Map.has_key?(def_of(Revision, rev.id), "href")
    assert Enum.map(stats.refused_links, & &1.table) |> Enum.sort() == ["documents", "revisions"]

    scope = [workspace_id: ws.id, project_id: proj.id]
    {:ok, _} = Content.restore_revision(rev.id, doc.type, doc.dataset, scope)

    restored = Repo.get!(Document, doc.id).content
    assert LinkHrefFence.refused(restored, "") == []
    assert %{"refused_href" => "javascript:x"} = def_of(restored)
  end

  test "a linkAnnotation's address in any case or spacing, and data: and vbscript:, are stripped",
       %{ws: ws, doc: doc} do
    for {bad, key} <- [
          {body(%{"_type" => "linkAnnotation", "url" => " JaVa\tScript:x"}), "url"},
          {link("data:text/html,<b>x</b>"), "href"},
          {link("vbscript:x"), "href"}
        ] do
      put_body!(Document, doc.id, bad)
      {:ok, bundle} = WorkspaceBundle.export(ws.id)

      {:ok, %{refused_links: [_one]}} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

      stored = def_of(Document, doc.id)
      refute Map.has_key?(stored, key)
      assert Map.has_key?(stored, "refused_" <> key)
    end
  end

  test "an import into a new dataset strips the same way", %{ws: ws, doc: doc} do
    put_body!(Document, doc.id, link("javascript:x"))
    {:ok, bundle} = WorkspaceBundle.export(ws.id, dataset: doc.dataset)
    ws_b = create_workspace!("lhref-b-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "default")
    into = [into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]]

    {:ok, stats} = WorkspaceBundle.import_bundle(bundle, into)

    [copy] = Repo.all(from d in Document, where: d.workspace_id == ^ws_b.id)
    assert LinkHrefFence.refused(copy.content, "") == []
    assert %{"refused_href" => "javascript:x"} = def_of(copy.content)
    assert [%{table: "documents"}] = stats.refused_links
  end

  test "from a bundle file, each member read from disk, the same", %{ws: ws, doc: doc} do
    put_body!(Document, doc.id, link("javascript:x"))
    {:ok, path} = WorkspaceBundle.export_to_file(ws.id)
    put_body!(Document, doc.id, link("https://ok.example"))

    try do
      {:ok, stats} = WorkspaceBundle.import_bundle_file(path, mode: :merge)

      assert %{"refused_href" => "javascript:x"} = def_of(Document, doc.id)
      assert [%{table: "documents", doc_id: _}] = stats.refused_links
    after
      File.rm(path)
    end
  end

  test "a bundle with an https link imports as it was, with no findings", %{ws: ws, doc: doc} do
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    assert {:ok, %{refused_links: []}} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
    assert %{"href" => "https://ok.example"} = def_of(Document, doc.id)
  end

  test "after a strip the fence finds nothing, at any depth, and each strip is named" do
    content = %{
      "body" => link("javascript:a"),
      "meta" => %{
        "rows" => [
          %{
            "rt" =>
              body(%{"_type" => "linkAnnotation", "href" => "data:x", "url" => "https://ok"})
          }
        ]
      },
      "a/b" => link("https://fine")
    }

    {stripped, found} = LinkHrefCheck.strip_content(content, "")

    assert LinkHrefFence.refused(stripped, "") == []
    assert Enum.sort(found) == Enum.sort(LinkHrefFence.refused(content, ""))

    assert def_of(stripped["a/b"] |> then(&%{"body" => &1})) == %{
             "_type" => "link",
             "_key" => "m1",
             "href" => "https://fine"
           }
  end
end
