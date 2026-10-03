defmodule BarkparkWeb.FederatedSearchGrantNarrowingTest do
  @moduledoc """
  task-e6939d27b7e0b3aa (search half; the counts half shipped in #20882): the
  flat `GET /v1/search/:dataset` mounted only `[:api, :api_strict_bearer]`, so
  `ResolveTokenOwner` + `AssignGrantScope` never ran and `:grant_scoped_read`
  was never set. A grantee whose grant covers ONE (dataset, type) of Default
  therefore searched every type in Default. The route now folds the grant like
  the flat `/v1/data` reads do.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content, Repo}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery-staple-9"
  @probe "zebrafedgrant"

  setup do
    {ws, project} = ensure_default_scope!()
    ds = "fedsearch-grant-#{System.unique_integer([:positive])}"
    scope = [workspace_id: ws.id, project_id: project.id]

    for type <- ["post", "note"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          ds,
          scope
        )
    end

    for {id, type} <- [{"fg-post", "post"}, {"fg-note", "note"}] do
      {:ok, _} =
        Content.create_document(type, %{"_id" => id, "title" => "#{@probe} #{id}"}, ds, scope)

      {:ok, _} = Content.publish_document(id, type, ds, scope)
    end

    %{ws: ws, project: project, ds: ds}
  end

  defp user! do
    email = "fedsearch-grant-#{System.unique_integer([:positive])}@example.com"
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

  defp search(raw, ds) do
    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get("/v1/search/#{ds}?q=#{@probe}&surfaces=documents")

    {resp.status, resp.resp_body}
  end

  test "a grantee covering only (ds, post) finds no note", ctx do
    user = user!()
    raw = owned_token!(user)
    bind_grant!(ctx.ws, user, %{project_id: ctx.project.id, dataset: ctx.ds, type: "post"})

    {status, body} = search(raw, ctx.ds)

    assert status == 200
    assert body =~ "fg-post", "the grant's own type must still be searchable: #{body}"
    refute body =~ "fg-note", "LEAK: search returned a type outside the caller's grant"
  end

  test "CONTROL: a Default member still finds every type", ctx do
    user = user!()
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")
    raw = owned_token!(user)

    {status, body} = search(raw, ctx.ds)

    assert status == 200
    assert body =~ "fg-post"
    assert body =~ "fg-note"
  end
end
