defmodule BarkparkWeb.MutateLinkHrefTest do
  @moduledoc """
  task-b923a915151d2038: a JSON write could store a Portable Text link whose
  address is `javascript:`, `data:` or `vbscript:`. #28371 draws such a link
  as its words and the editors never make one (TanStack's `linkHref`, the
  Classic editor's `from_html`), but the API, an import or another client
  could still write it, and every other reader of the stored JSON would get
  it. A write that brings in an address `Content.LinkHref` refuses is
  refused on every dataset, with the finding `pt_link_href_refused`. An
  address the row (or its draft or published twin) already holds is not new:
  a stored row with one stays editable.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("href-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "hrefpost",
          "title" => "HrefPost",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "meta",
              "type" => "composite",
              "fields" => [%{"name" => "rt", "type" => "richText"}]
            }
          ]
        },
        @dataset,
        scope
      )

    raw = "href-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "href", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw)}
  end

  defp rt(defs) do
    [
      %{
        "_type" => "block",
        "_key" => "k1",
        "style" => "normal",
        "markDefs" => defs,
        "children" => [
          %{"_type" => "span", "_key" => "s1", "text" => "go ", "marks" => []},
          %{"_type" => "span", "_key" => "s2", "text" => "here", "marks" => ["m1"]}
        ]
      }
    ]
  end

  defp link(href), do: rt([%{"_type" => "link", "_key" => "m1", "href" => href}])

  defp mutate(conn, mutation) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => [mutation]}))
  end

  defp create(conn, id, rt) do
    mutate(conn, %{
      "create" => %{
        "_type" => "hrefpost",
        "doc_id" => id,
        "title" => "T",
        "content" => %{"meta" => %{"rt" => rt}}
      }
    })
  end

  defp set_fields(conn, id, set),
    do: mutate(conn, %{"patch" => %{"id" => id, "type" => "hrefpost", "set" => set}})

  defp id, do: "href-#{System.unique_integer([:positive])}"

  # A create through the mutate door lands as the draft.
  defp stored(id, row \\ :draft)

  defp stored(id, :draft), do: stored("drafts." <> id, :row)

  defp stored(id, :row) do
    Repo.one(
      from d in Document, where: d.doc_id == ^id and d.type == "hrefpost", select: d.content
    )
  end

  # A row written before this check: the address put straight into storage.
  defp store_raw!(row_id, rt) do
    {1, _} =
      Repo.update_all(from(d in Document, where: d.doc_id == ^row_id and d.type == "hrefpost"),
        set: [content: %{"meta" => %{"rt" => rt}}]
      )
  end

  defp refused!(resp, path) do
    assert resp.status == 422, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "validation_failed"
    assert [%{"code" => "pt_link_href_refused", "path" => ^path}] = body["error"]["findings"]
  end

  for {label, href} <- [
        {"javascript:", "javascript:alert(1)"},
        {"in upper case", "JavaScript:alert(1)"},
        {"after spaces", "  javascript:alert(1)"},
        {"split by a tab", "jav\tascript:alert(1)"},
        {"after a control character", "\u0001javascript:alert(1)"},
        {"data:", "data:text/html,<script>alert(1)</script>"},
        {"vbscript:", "vbscript:msgbox(1)"},
        {"protocol-relative", "//evil.example/x"}
      ] do
    test "a create whose link address is #{label} is refused, and nothing is written", %{
      conn: conn
    } do
      id = id()
      refused!(create(conn, id, link(unquote(href))), "/meta/rt/0/markDefs/0/href")
      assert stored(id) == nil
    end
  end

  test "a linkAnnotation's url, href and damFileUrl are each checked", %{conn: conn} do
    for key <- ~w(url href damFileUrl) do
      defs = [%{"_type" => "linkAnnotation", "_key" => "m1", key => "javascript:alert(1)"}]
      refused!(create(conn, id(), rt(defs)), "/meta/rt/0/markDefs/0/#{key}")
    end
  end

  test "allowed addresses are written", %{conn: conn} do
    for href <- [
          "https://x.example",
          "mailto:a@x.example",
          "tel:+4712345678",
          "/p",
          "#top",
          "?q=1"
        ] do
      id = id()
      assert create(conn, id, link(href)).status == 200

      assert get_in(stored(id), ["meta", "rt", Access.at(0), "markDefs", Access.at(0), "href"]) ==
               href
    end
  end

  test "a row that already holds one stays editable; a new one in it is refused", %{conn: conn} do
    id = id()
    assert create(conn, id, link("https://x.example")).status == 200
    store_raw!("drafts." <> id, link("javascript:alert(1)"))

    # Another field: the stored address is not new.
    assert set_fields(conn, id, %{"title" => "T2"}).status == 200

    # The rich text itself, the old address kept and a word added.
    kept =
      put_in(
        link("javascript:alert(1)"),
        [Access.at(0), "children", Access.at(0), "text"],
        "go there "
      )

    assert set_fields(conn, id, %{"meta" => %{"rt" => kept}}).status == 200

    # A second, new address.
    two =
      rt([
        %{"_type" => "link", "_key" => "m1", "href" => "javascript:alert(1)"},
        %{"_type" => "link", "_key" => "m2", "href" => "data:text/html,x"}
      ])

    refused!(set_fields(conn, id, %{"meta" => %{"rt" => two}}), "/meta/rt/0/markDefs/1/href")
  end

  test "an address the published row holds is not new to its draft", %{conn: conn} do
    id = id()

    assert create(conn, id, link("https://x.example")).status == 200
    assert mutate(conn, %{"publish" => %{"id" => id, "type" => "hrefpost"}}).status == 200

    store_raw!(id, link("javascript:alert(1)"))
    assert stored(id, :row)["meta"]["rt"] == link("javascript:alert(1)")
    assert stored(id) == nil

    # The draft's first write carries the published row's address.
    assert set_fields(conn, id, %{"title" => "T2"}).status == 200
    assert stored(id)["meta"]["rt"] == link("javascript:alert(1)")
  end

  # The kernel door an import or a plugin writes through, and the upsert the
  # Studio's form save makes (`Forms` -> `Content.upsert_document/4`).
  describe "behind the HTTP door" do
    setup do
      ws = Barkpark.Tenancy.get_default_workspace()
      {_ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "hrefpost",
            "title" => "HrefPost",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "meta",
                "type" => "composite",
                "fields" => [%{"name" => "rt", "type" => "richText"}]
              }
            ]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      :ok
    end

    test "Content.create_document refuses a new one" do
      assert {:error, {:schema_validation_failed, _errors, [finding]}} =
               Content.create_document(
                 "hrefpost",
                 %{
                   "doc_id" => id(),
                   "title" => "T",
                   "content" => %{"meta" => %{"rt" => link("javascript:x")}}
                 },
                 @dataset
               )

      assert finding.code == :pt_link_href_refused
      assert finding.path == "/meta/rt/0/markDefs/0/href"
    end

    test "an upsert that keeps the stored one writes; one that swaps it in is refused" do
      id = id()

      {:ok, _} =
        Content.create_document(
          "hrefpost",
          %{
            "doc_id" => id,
            "title" => "T",
            "content" => %{"meta" => %{"rt" => link("https://x.example")}}
          },
          @dataset
        )

      store_raw!("drafts." <> id, link("javascript:x"))

      assert {:ok, _} =
               Content.upsert_document(
                 "hrefpost",
                 %{
                   "doc_id" => id,
                   "title" => "T2",
                   "content" => %{"meta" => %{"rt" => link("javascript:x")}}
                 },
                 @dataset
               )

      assert {:error, {:schema_validation_failed, _, [_]}} =
               Content.upsert_document(
                 "hrefpost",
                 %{
                   "doc_id" => id,
                   "title" => "T3",
                   "content" => %{"meta" => %{"rt" => link("vbscript:y")}}
                 },
                 @dataset
               )
    end
  end
end
