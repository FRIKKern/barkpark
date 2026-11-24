defmodule BarkparkWeb.MutateLinkHrefHtmlTest do
  @moduledoc """
  task-5272840f43511e20 (#28655 review, item 1): `LinkHrefFence` read only
  Portable Text `markDefs`, so a `richText` field holding an HTML string
  stored `<a href="javascript:…">` as given. The fence now reads each
  `<a href>` in such a string from a LazyHTML parse, with #28393's rules: a
  new `javascript:`, `vbscript:` or `data:` address is refused (422,
  `pt_link_href_refused`, nothing written), one the row already holds is
  not new, and a revision restore puts back what was stored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @type_name "hrefhtml"

  setup %{conn: conn} do
    ws = create_workspace!("hrefhtml-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "HrefHtml",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "body", "type" => "richText"},
            %{"name" => "notes", "type" => "text"},
            %{"name" => "blob", "type" => "json"},
            %{
              "name" => "meta",
              "type" => "composite",
              "fields" => [%{"name" => "rt", "type" => "richText"}]
            },
            %{
              "name" => "rows",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [%{"name" => "rt", "type" => "richText"}]
              }
            }
          ]
        },
        @dataset,
        scope
      )

    raw = "hrefhtml-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "hrefhtml", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw), scope: scope}
  end

  defp mutate(conn, mutation) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => [mutation]}))
  end

  defp create(conn, id, content),
    do:
      mutate(conn, %{
        "create" => %{"_type" => @type_name, "doc_id" => id, "title" => "T", "content" => content}
      })

  defp set_fields(conn, id, set),
    do: mutate(conn, %{"patch" => %{"id" => id, "type" => @type_name, "set" => set}})

  defp id, do: "hrefhtml-#{System.unique_integer([:positive])}"

  defp stored(id) do
    Repo.one(
      from d in Document,
        where: d.doc_id == ^("drafts." <> id) and d.type == @type_name,
        select: d.content
    )
  end

  # A row written before this check: the content put straight into storage.
  defp store_raw!(id, content) do
    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^("drafts." <> id) and d.type == @type_name),
        set: [content: content]
      )
  end

  defp refused!(resp, paths) do
    assert resp.status == 422, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "validation_failed"

    assert Enum.map(body["error"]["findings"], & &1["code"]) |> Enum.uniq() == [
             "pt_link_href_refused"
           ]

    assert Enum.map(body["error"]["findings"], & &1["path"]) == paths
  end

  describe "an HTML-string rich text value" do
    for {label, html} <- [
          {"javascript:", ~s|<p>go <a href="javascript:x">here</a></p>|},
          {"upper case", ~s|<P><A HREF="JavaScript:alert(1)">x</A></P>|},
          {"a tab inside the scheme", ~s|<p><a href="JAVA\tSCRIPT:alert(3)">x</a></p>|},
          {"a character reference", ~s|<p><a href="java&#x09;script:alert(3)">x</a></p>|},
          {"an encoded colon", ~s|<p><a href="javascript&#58;alert(1)">x</a></p>|},
          {"unquoted", ~s|<a href=javascript:alert(1)>x</a>|},
          {"a slash for a space", ~s|<a/href="javascript:alert(1)">x</a>|},
          {"vbscript:", ~s|<a href='vbscript:msgbox(1)'>x</a>|},
          {"data:", ~s|<a href="data:text/html,<script>alert(1)</script>">x</a>|},
          {"an area", ~s|<map><area href="javascript:alert(1)"></map>|}
        ] do
      @html html
      test "a create holding #{label} is refused, and nothing is written", %{conn: conn} do
        id = id()
        refused!(create(conn, id, %{"body" => @html}), ["/body"])
        assert stored(id) == nil
      end
    end

    test "nested in an object and in an array row, each is refused at its field", %{conn: conn} do
      js = ~s|<a href="javascript:x">x</a>|

      refused!(
        create(conn, id(), %{
          "meta" => %{"rt" => js},
          "rows" => [%{"rt" => "<p>ok</p>"}, %{"rt" => js}]
        }),
        ["/meta/rt", "/rows/1/rt"]
      )
    end

    test "a patch that brings one in is refused, and the row keeps what it had", %{conn: conn} do
      id = id()
      assert create(conn, id, %{"body" => "<p>clean</p>"}).status == 200
      refused!(set_fields(conn, id, %{"body" => ~s|<a href="javascript:x">x</a>|}), ["/body"])
      assert stored(id)["body"] == "<p>clean</p>"
    end

    test "every address that is not script is written as given", %{conn: conn} do
      id = id()

      html =
        ~s|<p><a href="https://x.example/a?b=1&amp;c=2">a</a> <a href="mailto:a@x.example">m</a> | <>
          ~s|<a href="/p/1">p</a> <a href="docs/x">d</a> <a href="">e</a> <a>none</a> | <>
          ~s|<a data-refused-href="javascript:x">kept words</a></p>|

      assert create(conn, id, %{"body" => html}).status == 200
      assert stored(id)["body"] == html
    end

    test "a string or text field holding markup is not rich text", %{conn: conn} do
      id = id()
      markup = ~s|<a href="javascript:x">x</a>|

      assert create(conn, id, %{"title" => markup, "notes" => markup, "blob" => %{"h" => markup}}).status ==
               200

      assert stored(id)["notes"] == markup
    end

    test "a row that already holds one stays editable; a new one in it is refused", %{conn: conn} do
      id = id()
      assert create(conn, id, %{"body" => "<p>clean</p>"}).status == 200
      held = ~s|<p><a href="javascript:legacy">old</a></p>|
      store_raw!(id, %{"body" => held})

      assert set_fields(conn, id, %{"title" => "T2"}).status == 200
      assert stored(id)["body"] == held

      typed = ~s|<p><a href="javascript:legacy">old</a>, typed</p>|
      assert set_fields(conn, id, %{"body" => typed}).status == 200

      refused!(
        set_fields(conn, id, %{"body" => typed <> ~s|<a href="javascript:new">n</a>|}),
        ["/body"]
      )
    end

    test "a revision restore puts back a stored javascript: link", %{conn: conn, scope: scope} do
      id = id()
      assert create(conn, id, %{"body" => "<p>clean</p>"}).status == 200
      store_raw!(id, %{"body" => ~s|<p><a href="javascript:legacy">x</a></p>|})
      assert set_fields(conn, id, %{"title" => "T2"}).status == 200
      assert set_fields(conn, id, %{"body" => "<p>clean again</p>"}).status == 200

      {rid, _} =
        Repo.all(
          from r in Barkpark.Content.Revision,
            where: r.doc_id in ^[id, "drafts." <> id],
            order_by: [asc: r.inserted_at],
            select: {r.id, r.content}
        )
        |> Enum.find(fn {_rid, c} -> inspect(c) =~ "javascript:legacy" end)

      assert {:ok, _} = Content.restore_revision(rid, @type_name, @dataset, scope)
      assert stored(id)["body"] =~ ~s|href="javascript:legacy"|
    end
  end
end
