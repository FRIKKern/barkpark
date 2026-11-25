defmodule Barkpark.Tenancy.WorkspaceBundleLinkHrefTest do
  @moduledoc """
  task-9d0496cb3f369ed1 (#28393 review): a bundle import writes rows by raw
  COPY, past the Writer's `LinkHrefFence`, so a bundle stored a link whose
  address was `javascript:`. The import now refuses such a bundle before it
  writes anything.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError

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

  defp href(doc),
    do:
      get_in(Repo.get!(Document, doc.id).content, ["body", Access.at(0), "markDefs", Access.at(0)])

  setup do
    ws = create_workspace!("lhref-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")

    {:ok, doc} =
      create_document_in!(ws, proj, "post", %{
        "doc_id" => "lh1",
        "body" => link("https://ok.example")
      })

    %{ws: ws, doc: doc}
  end

  test "a document whose link carries javascript: is refused, and nothing is written",
       %{ws: ws, doc: doc} do
    put_body!(Document, doc.id, link("javascript:alert(1)"))
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    put_body!(Document, doc.id, link("https://ok.example"))

    e =
      assert_raise InvalidBundleError, fn ->
        WorkspaceBundle.import_bundle(bundle, mode: :merge)
      end

    assert e.code == "pt_link_href_refused"
    assert e.message =~ "documents #{doc.doc_id} /body/0/markDefs/0/href"
    assert %{"href" => "https://ok.example"} = href(doc)
  end

  test "a linkAnnotation's address in any case or spacing, and data:, are refused", %{
    ws: ws,
    doc: doc
  } do
    for bad <- [
          body(%{"_type" => "linkAnnotation", "url" => " JaVa\tScript:x"}),
          link("data:text/html,<b>x</b>"),
          link("vbscript:x")
        ] do
      put_body!(Document, doc.id, bad)
      {:ok, bundle} = WorkspaceBundle.export(ws.id)

      assert %InvalidBundleError{code: "pt_link_href_refused"} =
               catch_error(WorkspaceBundle.import_bundle(bundle, mode: :merge))
    end
  end

  test "a revision whose content carries one is refused too: a restore skips the fence",
       %{ws: ws, doc: doc} do
    # A revision must match its document when it is written; the document
    # then moves on to a clean link, so only the revision holds the address.
    put_body!(Document, doc.id, link("javascript:x"))
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

    put_body!(Document, doc.id, link("https://ok.example"))

    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    e =
      assert_raise InvalidBundleError, fn ->
        WorkspaceBundle.import_bundle(bundle, mode: :merge)
      end

    assert e.message =~ "revisions lh1 /body/0/markDefs/0/href"
  end

  test "an import into a new dataset is refused the same way", %{ws: ws, doc: doc} do
    put_body!(Document, doc.id, link("javascript:x"))
    {:ok, bundle} = WorkspaceBundle.export(ws.id, dataset: doc.dataset)
    ws_b = create_workspace!("lhref-b-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "default")
    into = [into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "copy"]]

    assert %InvalidBundleError{code: "pt_link_href_refused"} =
             catch_error(WorkspaceBundle.import_bundle(bundle, into))

    assert Repo.aggregate(from(d in Document, where: d.workspace_id == ^ws_b.id), :count) == 0
  end

  test "a bundle with an https link imports", %{ws: ws, doc: doc} do
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    assert {:ok, _stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
    assert %{"href" => "https://ok.example"} = href(doc)
  end
end
