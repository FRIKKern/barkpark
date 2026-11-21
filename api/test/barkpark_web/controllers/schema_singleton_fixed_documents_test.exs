defmodule BarkparkWeb.SchemaSingletonFixedDocumentsTest do
  @moduledoc """
  task-f235c9f16a976e57: a singleton's one document has the type's name as
  its id. With `fixedDocuments` set and that id not in the list, the document
  could never be created, yet the schema saved. Now every write of that shape
  is refused 422 on `fixed_documents`, a re-save of one already stored too.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Repo

  @admin_token "barkpark-dev-token-schema-singleton-fixed"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-singleton-fixed-test", [
      "read",
      "write",
      "admin"
    ])

    %{name: "innstillinger_#{System.unique_integer([:positive])}"}
  end

  defp post_schema(body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/v1/schemas/test", Jason.encode!(body))
  end

  defp schema(name, extra),
    do:
      Map.merge(
        %{
          "name" => name,
          "title" => "Innstillinger",
          "fields" => [%{"name" => "t", "type" => "string"}]
        },
        extra
      )

  defp saved?(resp), do: resp.status in [200, 201]

  defp refused_on_fixed?(resp),
    do: resp.status == 422 and String.contains?(resp.resp_body, "fixed_documents")

  test "a singleton whose list leaves out its own id is refused; [name], no list or null saves",
       %{
         name: name
       } do
    resp = post_schema(schema(name, %{"singleton" => true, "fixedDocuments" => ["side-om-oss"]}))
    assert refused_on_fixed?(resp), resp.resp_body

    resp = post_schema(schema(name, %{"singleton" => true, "fixedDocuments" => []}))
    assert refused_on_fixed?(resp), resp.resp_body

    for extra <- [
          %{"singleton" => true, "fixedDocuments" => [name]},
          %{"singleton" => true, "fixedDocuments" => ["side-om-oss", name]},
          %{"singleton" => true},
          %{"singleton" => true, "fixedDocuments" => nil},
          %{"singleton" => false, "fixedDocuments" => ["side-om-oss"]}
        ] do
      resp = post_schema(schema(name, extra))
      assert saved?(resp), "#{inspect(extra)}: #{resp.resp_body}"
    end
  end

  test "a later write that makes the shape is refused: flipping singleton on, or dropping the id",
       %{name: name} do
    assert post_schema(schema(name, %{"fixedDocuments" => ["side-om-oss"]})).status == 201
    assert refused_on_fixed?(post_schema(%{"name" => name, "singleton" => true}))

    assert saved?(post_schema(%{"name" => name, "singleton" => true, "fixedDocuments" => [name]}))

    assert refused_on_fixed?(post_schema(%{"name" => name, "fixedDocuments" => ["side-om-oss"]}))
  end

  test "a schema already stored that way is refused on its next save too", %{name: name} do
    assert saved?(post_schema(schema(name, %{"singleton" => true})))

    # As a schema saved before this check: put straight into the row.
    Barkpark.Content.SchemaDefinition
    |> Repo.get_by!(name: name)
    |> Ecto.Changeset.change(fixed_documents: ["side-om-oss"])
    |> Repo.update!()

    assert refused_on_fixed?(post_schema(%{"name" => name, "title" => "Ny"}))

    assert saved?(post_schema(%{"name" => name, "fixedDocuments" => nil}))
  end
end
