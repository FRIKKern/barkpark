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
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, InvalidBundleError, LinkHrefCheck}

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
               column: "content",
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

  # The bundle with its `documents` member's bytes passed through `edit`, as
  # a hand-edited bundle would be (#28728 review).
  defp edited(bundle, member, edit) do
    {:ok, entries} = :erl_tar.extract({:binary, bundle}, [:memory])
    name = ~c"tables/#{member}.copy"
    path = Path.join(System.tmp_dir!(), "lhref-#{System.unique_integer([:positive])}.tar")
    {:ok, tar} = :erl_tar.open(path, [:write])

    for {n, bytes} <- entries do
      :ok = :erl_tar.add(tar, if(n == name, do: edit.(bytes), else: bytes), n, [])
    end

    :ok = :erl_tar.close(tar)
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp put_raw!(table, id, json) do
    Repo.query!("UPDATE #{table} SET content = $2::text::jsonb WHERE id = $1", [
      Ecto.UUID.dump!(id),
      json
    ])
  end

  # A key spelled with a JSON or a COPY escape is the same key once Postgres
  # has read the row; the check read the raw bytes (#28728 review, 1).
  for {name, spelling} <- [
        {"a JSON escape", ~S(\\u006darkDefs)},
        {"a COPY hex escape", ~S(\x6darkDefs)},
        {"a COPY octal escape", ~S(\155arkDefs)}
      ] do
    test "a markDefs key spelled with #{name} is stripped", %{ws: ws, doc: doc} do
      put_body!(Document, doc.id, link("javascript:alert(1)"))
      {:ok, bundle} = WorkspaceBundle.export(ws.id)
      bundle = edited(bundle, "documents", &String.replace(&1, "markDefs", unquote(spelling)))
      put_body!(Document, doc.id, link("https://ok.example"))

      {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

      stored = Repo.get!(Document, doc.id).content
      assert LinkHrefFence.refused(stored, "") == []
      assert %{"refused_href" => "javascript:alert(1)"} = def_of(stored)
      assert [%{path: "/body/0/markDefs/0/href"}] = stats.refused_links
    end
  end

  # Jason refused `1e400`, which jsonb stores, and the row went through
  # unchecked (#28728 review, 2). Every number is kept as written (5).
  test "a row with numbers Jason's floats cannot hold is stripped, every number kept",
       %{ws: ws, doc: doc} do
    body = Jason.encode!(link("javascript:x"))

    put_raw!(
      "documents",
      doc.id,
      ~s({"n":1e400,"p":19.990000000000000001,"q":1.10,"body":#{body}})
    )

    numbers = "SELECT (content - 'body')::text FROM documents WHERE id = $1"
    %{rows: [[before]]} = Repo.query!(numbers, [Ecto.UUID.dump!(doc.id)])
    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    assert [%{table: "documents"}] = stats.refused_links
    assert %{"refused_href" => "javascript:x"} = def_of(Document, doc.id)
    %{rows: [[now]]} = Repo.query!(numbers, [Ecto.UUID.dump!(doc.id)])
    assert now == before
    assert now =~ "19.990000000000000001" and now =~ "1.10"
  end

  # task-ff1f9481f31ad3bc (#28728 r2 review): `COPY FROM` ends a row at a
  # bare CR too, and stops at a `\\.` line; the check split on newlines only.
  # The javascript: link sits in the member's last row.
  defp last_link_row(bytes) do
    rows = bytes |> String.split("\n", trim: true)
    {bad, ok} = Enum.split_with(rows, &String.contains?(&1, "javascript:"))
    {ok, bad}
  end

  defp refused(bundle) do
    WorkspaceBundle.import_bundle(bundle, mode: :merge)
  rescue
    e in InvalidBundleError -> {:raised, e}
  end

  for {name, join} <- [
        {"a member whose rows end with a bare CR", :cr},
        {"a member with a \\. line before the link's row", :eod}
      ] do
    test "#{name} is refused, and no javascript: link is stored", %{ws: ws, proj: proj, doc: doc} do
      {:ok, two} =
        create_document_in!(ws, proj, "post", %{
          "doc_id" => "lh2",
          "body" => link("https://ok.example")
        })

      put_body!(Document, two.id, link("javascript:cr"))
      {:ok, bundle} = WorkspaceBundle.export(ws.id)
      put_body!(Document, two.id, link("https://ok.example"))

      bundle =
        edited(bundle, "documents", fn bytes ->
          {ok, bad} = last_link_row(bytes)

          case unquote(join) do
            :cr -> Enum.join(ok ++ bad, "\r") <> "\r"
            :eod -> Enum.join(ok ++ ["\\."] ++ bad, "\n") <> "\n"
          end
        end)

      result = refused(bundle)

      assert match?({:raised, %{code: "copy_rows_unreadable"}}, result) or
               match?({:error, %{code: "copy_rows_unreadable"}}, result),
             "imported: #{inspect(result, limit: 5)}"

      for d <- [doc, two],
          do: assert(LinkHrefFence.refused(Repo.get!(Document, d.id).content, "") == [])

      assert %{"href" => "https://ok.example"} = def_of(Document, two.id)
    end
  end

  test "a value the check cannot decode refuses the bundle, by name", %{ws: ws, doc: doc} do
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    {manifest, dumps} = Archive.unpack(bundle)

    dumps =
      Map.update!(dumps, "documents", &String.replace(&1, ~s("markDefs":), ~s("markDefs"::)))

    error = assert_raise InvalidBundleError, fn -> LinkHrefCheck.strip(manifest, dumps) end
    assert error.code == "pt_content_undecodable"
    assert error.message =~ doc.doc_id
  end

  # The listen replay, the sync outbox and the webhook rebuild serve
  # `mutation_events.document` (#28728 review, 4).
  test "a mutation event's document snapshot is stripped too", %{ws: ws, doc: doc} do
    event = fn href ->
      %{
        dataset: doc.dataset,
        type: doc.type,
        doc_id: doc.doc_id,
        mutation: "delete",
        rev: "r1",
        document: %{"_id" => doc.doc_id, "body" => link(href)},
        inserted_at: NaiveDateTime.utc_now(:second),
        workspace_id: Ecto.UUID.dump!(ws.id),
        source: "api"
      }
    end

    {1, [%{id: id}]} =
      Repo.insert_all("mutation_events", [event.("javascript:x")], returning: [:id])

    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    Repo.query!("DELETE FROM mutation_events WHERE id = $1", [id])

    {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)

    %{rows: [[stored]]} = Repo.query!("SELECT document FROM mutation_events WHERE id = $1", [id])
    assert LinkHrefFence.refused(stored, "") == []
    assert %{"refused_href" => "javascript:x"} = def_of(stored)

    assert %{column: "document"} =
             Enum.find(stats.refused_links, &(&1.table == "mutation_events"))
  end

  # The columns read are the target's json and jsonb columns, from its own
  # schema, so a member added later is read with no list to update. Held
  # against the bundle's own member list and an independent read of the
  # catalog (pg_attribute, not information_schema).
  test "every json and jsonb column of every bundle member is read", %{ws: ws} do
    {:ok, bundle} = WorkspaceBundle.export(ws.id)
    {manifest, _dumps} = Archive.unpack(bundle)
    members = for %{"name" => t, "columns" => cols} <- manifest["tables"], do: {t, cols}

    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname, a.attname FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE c.relname = ANY($1) AND a.attnum > 0 AND NOT a.attisdropped
          AND format_type(a.atttypid, a.atttypmod) IN ('json', 'jsonb')
        """,
        [Enum.map(members, &elem(&1, 0))]
      )

    read = LinkHrefCheck.json_columns(Enum.map(members, &elem(&1, 0)))
    exported = Map.new(members)

    for [table, column] <- rows, column in exported[table] do
      assert column in Map.get(read, table, []), "#{table}.#{column} is not read"
    end

    assert "content" in read["documents"] and "content" in read["revisions"]
    assert "document" in read["mutation_events"]
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
