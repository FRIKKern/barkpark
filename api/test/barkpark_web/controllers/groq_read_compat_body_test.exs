defmodule BarkparkWeb.GroqReadCompatBodyTest do
  @moduledoc """
  task-c2be444ac1d07719, slice 4: GROQ reads a declared richText field stored
  as PortableDoc as Sanity reads the Portable Text it maps from. Expected
  values are Sanity's, read from ecu57yeh/e2e-local on 2026-10-26 for the same
  shape (post-11: pt::text(body) "Heading\\n\\nBody paragraph for post
  11.\\n\\nStatus , written with Ada."; its internalLink to author-ada makes
  references('author-ada') count it). Nothing stored changes.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_body_ds"

  @blocks %{
    "styles" => ["normal", "h2", "blockquote"],
    "lists" => ["bullet"],
    "marks" => ["strong"],
    "annotations" => [%{"name" => "link"}, %{"name" => "wikilink"}],
    "inline" => [%{"name" => "chip", "fields" => [%{"name" => "text", "type" => "string"}]}],
    "of" => [%{"name" => "callout", "fields" => [%{"name" => "text", "type" => "text"}]}]
  }

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-body", name: "GROQ body"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    rich = fn name ->
      %{"name" => name, "type" => "richText", "editor" => "blocks", "blocks" => @blocks}
    end

    for {name, fields} <- [
          {"author", [%{"name" => "name", "type" => "string"}]},
          {"post",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "author", "type" => "reference", "refType" => "author"},
             rich.("body"),
             Map.put(rich.("notes"), "private", true)
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @dataset,
          scope
        )
    end

    text = fn v -> %{"type" => "text", "value" => v} end

    link = fn id ->
      %{"type" => "wikilink", "docId" => id, "target" => id, "children" => [text.("Ada")]}
    end

    linked_body = %{
      "blocks" => [
        %{"id" => "h", "type" => "heading", "level" => 2, "content" => [text.("Heading")]},
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [text.("Body paragraph for post 11.")]
        },
        %{
          "id" => "p2",
          "type" => "paragraph",
          "content" => [
            text.("Status "),
            %{"type" => "chip", "text" => "Reviewed"},
            text.(", written with "),
            link.("ada"),
            text.(".")
          ]
        },
        %{"id" => "co", "type" => "callout", "content" => [text.("A custom block.")]},
        %{
          "id" => "l",
          "type" => "list",
          "ordered" => false,
          "items" => [[text.("One")], [%{"type" => "strong", "children" => [text.("Two")]}]]
        }
      ]
    }

    plain = %{"blocks" => [%{"id" => "p", "type" => "paragraph", "content" => [text.("Plain.")]}]}

    docs = [
      {"author", "ada", %{"name" => "Ada"}},
      {"post", "p1", %{"body" => linked_body}},
      # Links ada only in a private field.
      {"post", "p2", %{"body" => plain, "notes" => linked_body}},
      # A direct bare reference, no body link.
      {"post", "p3", %{"author" => "ada", "body" => plain}},
      {"post", "p4", %{"body" => plain}}
    ]

    for {type, id, content} <- docs do
      {:ok, _} =
        Content.create_document(
          type,
          Map.merge(%{"_id" => id, "title" => id}, content),
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(id, type, @dataset, scope)
    end

    # A read-only member token: not an admin, so `notes` is redacted for it.
    token = "groq-body-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "body", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  defp q(conn, token, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-body/p/site/v2025-02-19/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "pt::text reads a declared PortableDoc body as Sanity's text", %{conn: conn, token: t} do
    expected =
      "Heading\n\nBody paragraph for post 11.\n\nStatus , written with Ada.\n\nOne\n\nTwo"

    assert q(conn, t, ~s|pt::text(*[_id == "p1"][0].body)|) == expected
    assert q(conn, t, ~s|*[_id == "p1"][0]{"t": pt::text(body)}|) == %{"t" => expected}
    assert q(conn, t, ~s|*[_id == "p4"][0]{"t": pt::text(body)}|) == %{"t" => "Plain."}
    assert q(conn, t, ~s|*[_id == "p1"][0]{"t": pt::text(title)}|) == %{"t" => nil}
    # The stored body is unchanged.
    assert %{"blocks" => [_ | _]} = q(conn, t, ~s|*[_id == "p1"][0].body|)
  end

  test "a body link counts for references(), a private body's never does", %{conn: conn, token: t} do
    assert q(conn, t, ~s|*[_id == "p1"][0]{"r": references("ada")}|) == %{"r" => true}
    assert q(conn, t, ~s|*[_id == "p2"][0]{"r": references("ada")}|) == %{"r" => false}
    assert q(conn, t, ~s|*[_id == "p4"][0]{"r": references("ada")}|) == %{"r" => false}
  end

  test "references() in a filter finds a body link in SQL, beside a direct bare reference", %{
    conn: conn,
    token: t
  } do
    # p1: a body link; p3: a direct bare `author`, no body link (it never
    # depends on any body or edge state); p2's link is in a private field.
    assert q(conn, t, ~s|*[_type == "post" && references("ada")] \| order(_id)._id|) == [
             "p1",
             "p3"
           ]

    assert q(conn, t, ~s|count(*[_type == "post" && references("ada")])|) == 2
    assert q(conn, t, ~s|count(*[references("ada")])|) == 2
    assert q(conn, t, ~s|*[references("nobody")]._id|) == []
  end

  # No index serves a body link's `.**` jsonpath: the probe must stay inside
  # the declaring type's rows, typeless or not, and never read a private field.
  test "the body-link probe is bounded by its type and skips private fields", %{
    conn: conn,
    token: t
  } do
    test_pid = self()
    handler = "groq-body-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _cfg -> send(test_pid, {:sql, meta.params}) end,
      nil
    )

    try do
      assert q(conn, t, ~s|count(*[references("ada")])|) == 2
    after
      :telemetry.detach(handler)
    end

    probes =
      for params <- drain_params([]),
          p <- params,
          is_binary(p) and p =~ "wikilink",
          do: {p, params}

    assert probes != []
    assert Enum.all?(probes, fn {_p, params} -> "post" in params end)
    assert Enum.all?(probes, fn {p, _params} -> p =~ ~s|$."body"| and not (p =~ "notes") end)
  end

  defp drain_params(acc) do
    receive do
      {:sql, params} -> drain_params([params | acc])
    after
      0 -> acc
    end
  end
end
