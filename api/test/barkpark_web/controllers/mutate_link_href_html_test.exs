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
              "name" => "lt",
              "type" => "localizedText",
              "languages" => ["nb", "en"],
              "format" => "rich"
            },
            %{
              "name" => "ltp",
              "type" => "localizedText",
              "languages" => ["nb"],
              "format" => "plain"
            },
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

  defp mutate(conn, mutation), do: mutate_all(conn, [mutation])

  defp mutate_all(conn, mutations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
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
  defp store_raw!(id, content, row \\ :draft) do
    row_id = if row == :draft, do: "drafts." <> id, else: id

    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^row_id and d.type == @type_name),
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

    test "a string, text, json or undeclared value holding markup is not rich text", %{conn: conn} do
      id = id()
      markup = ~s|<a href="javascript:x">x</a>|

      content = %{
        "title" => markup,
        "notes" => markup,
        "blob" => %{"h" => markup},
        "extra" => markup
      }

      assert create(conn, id, content).status == 200
      assert stored(id)["notes"] == markup
      assert stored(id)["extra"] == markup
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

  # #28695 review r1, blocking: an address held only where the fence does not
  # look (text, undeclared, json, or the twin's such a field) is not held.
  describe "held is read where the fence reads" do
    @payload ~s|<a href="javascript:evil()">x</a>|

    test "one request: a create that puts it in a text field, then a patch into rich text", %{
      conn: conn
    } do
      id = id()

      resp =
        mutate_all(conn, [
          %{
            "create" => %{
              "_type" => @type_name,
              "doc_id" => id,
              "title" => "T",
              "content" => %{"notes" => @payload}
            }
          },
          %{"patch" => %{"id" => id, "type" => @type_name, "set" => %{"body" => @payload}}}
        ])

      refused!(resp, ["/body"])
      assert stored(id) == nil
    end

    for {label, content} <- [
          {"a text field", %{"notes" => ~s|<a href="javascript:evil()">x</a>|}},
          {"an undeclared field", %{"zz" => ~s|<a href="javascript:evil()">x</a>|}},
          {"a json field holding markDefs",
           %{
             "blob" => [
               %{
                 "_type" => "block",
                 "markDefs" => [
                   %{"_type" => "link", "_key" => "m", "href" => "javascript:evil()"}
                 ]
               }
             ]
           }}
        ] do
      @content content
      test "two writes: #{label} does not hold it for rich text", %{conn: conn} do
        id = id()
        assert create(conn, id, @content).status == 200
        refused!(set_fields(conn, id, %{"body" => @payload}), ["/body"])
        refute (stored(id)["body"] || "") =~ "javascript:"
      end
    end

    test "the published twin's text field does not hold it for the draft", %{conn: conn} do
      id = id()
      assert create(conn, id, %{"body" => "<p>clean</p>"}).status == 200
      assert mutate(conn, %{"publish" => %{"id" => id, "type" => @type_name}}).status == 200
      store_raw!(id, %{"body" => "<p>clean</p>", "notes" => @payload}, :published)

      refused!(set_fields(conn, id, %{"body" => @payload}), ["/body"])
    end

    test "held in rich text: a legacy HTML row converted to Portable Text keeps its address", %{
      conn: conn
    } do
      id = id()
      assert create(conn, id, %{"body" => "<p>clean</p>"}).status == 200
      store_raw!(id, %{"body" => ~s|<p><a href="javascript:legacy">old</a></p>|})

      pt = [
        %{
          "_type" => "block",
          "_key" => "b",
          "style" => "normal",
          "markDefs" => [%{"_type" => "link", "_key" => "m", "href" => "javascript:legacy"}],
          "children" => [%{"_type" => "span", "_key" => "s", "text" => "old", "marks" => ["m"]}]
        }
      ]

      assert set_fields(conn, id, %{"body" => pt}).status == 200
    end
  end

  describe "#28695 review r1, should fix" do
    # LazyHTML parses with scripting off; a browser drawing this with
    # scripting on reads noscript as raw text and gets a live link.
    test "a link a browser builds out of a noscript is refused", %{conn: conn} do
      html = ~s|<noscript><p title="</noscript><a href=javascript:alert(1)>x</a>"></p></noscript>|
      refused!(create(conn, id(), %{"body" => html}), ["/body"])

      upper =
        ~s|<NoScript><p title="</NOSCRIPT><a href=javascript:alert(1)>x</a>"></p></NoScript>|

      refused!(create(conn, id(), %{"body" => upper}), ["/body"])
    end

    test "a noscript with no link a browser would build is written", %{conn: conn} do
      id = id()

      html =
        ~s|<noscript><p title="a &lt;b&gt;">no script</p></noscript><a href="https://x.example">y</a>|

      assert create(conn, id, %{"body" => html}).status == 200
    end

    test "a rich localizedText is read per language; a plain one is not markup", %{conn: conn} do
      refused!(
        create(conn, id(), %{
          "lt" => %{"nb" => "<p>ok</p>", "en" => ~s|<a href="javascript:alert(1)">x</a>|}
        }),
        ["/lt/en"]
      )

      id = id()

      assert create(conn, id, %{"ltp" => %{"nb" => ~s|<a href="javascript:x">x</a>|}}).status ==
               200
    end
  end

  describe "#28695 review r2, should fix" do
    # View 2 reads noscript as xmp; the input's own `</xmp` must not close it,
    # since a browser ends noscript only at `</noscript`.
    test "an xmp end tag inside a noscript does not hide its link", %{conn: conn} do
      for html <- [
            ~s|<noscript></xmp><p title="</noscript><a href=javascript:alert(1)>x</a>"></p>|,
            ~s|<NOSCRIPT></XMP ><p title="</NOSCRIPT><a href=javascript:alert(1)>x</a>"></p>|
          ] do
        refused!(create(conn, id(), %{"body" => html}), ["/body"])
      end
    end

    # lexbor drops an `<a>` inside a select; Chrome's select parser keeps it.
    test "a link inside a select is refused", %{conn: conn} do
      for html <- [
            ~s|<select><a href="javascript:alert(1)">x</a></select>|,
            ~s|<SELECT><option>o</option><A HREF=javascript:alert(1)>x</A></SELECT>|,
            ~s|<select><noscript><p title="</noscript><a href=javascript:alert(1)>x</a>"></p></noscript></select>|
          ] do
        refused!(create(conn, id(), %{"body" => html}), ["/body"])
      end
    end

    test "a select, an xmp and a noscript beside a safe link are written", %{conn: conn} do
      html =
        ~s|<select><option>a</option></select><xmp><b></xmp>| <>
          ~s|<noscript>n</noscript><a href="https://x.example">y</a>|

      assert create(conn, id(), %{"body" => html}).status == 200
    end

    # Held addresses are read only when the new value has a refusable link:
    # a save with safe links parses the new value, never the stored row.
    test "a save with no refusable link does not parse the stored row", %{conn: conn} do
      id = id()
      assert create(conn, id, %{"body" => ~s|<a href="https://old.example">o</a>|}).status == 200

      parses =
        count_parses(fn ->
          assert set_fields(conn, id, %{"body" => ~s|<a href="https://new.example">n</a>|}).status ==
                   200
        end)

      assert parses == 1, "parsed #{parses} times"
    end
  end

  # LazyHTML.from_fragment/1 calls made by this process (and what it
  # spawns) while `fun` runs, counted by a separate tracer process.
  defp count_parses(fun) do
    mfa = {LazyHTML, :from_fragment, 1}
    me = self()
    counter = spawn_link(fn -> count_calls(me, 0) end)
    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, counter}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call, :set_on_spawn])
      :erlang.trace_pattern(mfa, false, [:global])
    end

    # Every trace message reaches the counter before `:done` does.
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
    send(counter, :done)
    assert_receive {:parses, n}
    n
  end

  defp count_calls(parent, n) do
    receive do
      {:trace, _pid, :call, {LazyHTML, :from_fragment, _args}} -> count_calls(parent, n + 1)
      :done -> send(parent, {:parses, n})
    end
  end
end
