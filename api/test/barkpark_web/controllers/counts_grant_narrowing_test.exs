defmodule BarkparkWeb.CountsGrantNarrowingTest do
  @moduledoc """
  task-e6939d27b7e0b3aa (counts half): `GET /v1/data/counts/:dataset` sits under
  `AssignGrantScope`, yet `published_type_counts/2` applied only the workspace and
  dataset filters. A grantee whose grant covers ONE (dataset, type) of Default
  therefore got the census of every type, outside the grant. It now applies the
  same owner + grant narrowing every document read applies.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content, Repo}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery-staple-9"

  setup do
    {ws, project} = ensure_default_scope!()
    ds = "counts-grant-#{System.unique_integer([:positive])}"

    for type <- ["post", "note"] do
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
        ds
      )
    end

    for {id, type} <- [{"p1", "post"}, {"n1", "note"}] do
      {:ok, _} = create_document_in!(ws, project, type, %{"_id" => id, "title" => id}, ds)
      {:ok, _} = Content.publish_document(id, type, ds)
    end

    %{ws: ws, project: project, ds: ds}
  end

  defp user! do
    email = "counts-grant-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp owned_token!(user) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "t",
        dataset: "test",
        permissions: ["read"],
        owner_user_id: user.id
      })
      |> Repo.insert()

    raw
  end

  defp counts(raw, ds) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get("/v1/data/counts/#{ds}")
    |> json_response(200)
  end

  defp types(body), do: body |> Jason.encode!() |> then(&{&1 =~ ~s("post"), &1 =~ ~s("note")})

  test "a grantee covering only (ds, post) gets no count for the note type", ctx do
    user = user!()
    raw = owned_token!(user)
    bind_grant!(ctx.ws, user, %{project_id: ctx.project.id, dataset: ctx.ds, type: "post"})

    {has_post, has_note} = types(counts(raw, ctx.ds))

    assert has_post, "the grant's own type must still be counted"
    refute has_note, "LEAK: counts reported a type outside the caller's grant"
  end

  test "CONTROL: a Default member still gets every type", ctx do
    user = user!()
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")
    raw = owned_token!(user)

    assert {true, true} = types(counts(raw, ctx.ds))
  end
end
