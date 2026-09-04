defmodule BarkparkWeb.Contract.FederatedGrantDenyTest do
  @moduledoc """
  ag-deny-matrix — the FEDERATED cell.

  `GET /v1/search/:dataset` (`FederatedSearchController`) rides the BARE `:api`
  pipeline (router.ex ~1270) — NOT `:api_grant_read`. There is no
  `AssignGrantScope` on this route, so a grant is NEVER folded here: a grant-only
  principal reads the DEFAULT (back-compat) scope only and a grant can never
  WIDEN federated discovery to the granted workspace. Fail-closed by absence of
  the fold, proven non-vacuously: a doc that the principal's grant DOES cover (in
  another workspace) stays invisible, while a Default-scope doc IS returned (so
  the search genuinely ran, it is not empty-by-accident).

  This records the deliberate bare-`:api` design — the enforcement surfaces are
  the flat `/v1/data` reads (grant-narrowed) and the scoped `/w/:ws` reads; the
  federated discovery endpoint is intentionally not a grant-narrowing surface, so
  it must never be grant-WIDENED either.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo

  @password "correct-horse-battery"
  @ds "granted"
  @term "federatedgrantterm"

  setup do
    {default_ws, default_proj} = ensure_default_scope!()

    Content.upsert_schema(
      %{"name" => "post", "title" => "post", "visibility" => "public", "fields" => []},
      @ds
    )

    seed = fn ws, proj, id, title ->
      {:ok, _} = create_document_in!(ws, proj, "post", %{"_id" => id, "title" => title}, @ds)
      # publish is tenancy-scoped — a doc in a non-Default workspace is found only
      # under its own scope (a bare publish looks in Default and 404s).
      {:ok, _} =
        Content.publish_document(id, "post", @ds, workspace_id: ws.id, project_id: proj.id)
    end

    # A Default-scope hit (federated reads Default → this IS returned) and a hit
    # in a SEPARATE workspace that the principal's grant covers (federated must
    # NOT surface it — the grant does not reach this route).
    seed.(default_ws, default_proj, "default-hit", "#{@term} default")

    grant_ws = create_workspace!("fed-grant-ws-#{System.unique_integer([:positive])}")
    grant_proj = create_project!(grant_ws, "fed-grant-proj")
    seed.(grant_ws, grant_proj, "grant-hit", "#{@term} granted-workspace secret")

    {:ok, grant_ws: grant_ws, grant_proj: grant_proj}
  end

  defp register_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
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

  defp federated_titles(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/v1/search/#{@ds}?q=#{@term}&surfaces=documents")
    |> json_response(200)
    |> get_in(["results", "documents", "hits"])
    |> Enum.map(& &1["title"])
  end

  test "a grant-only principal fails closed to Default scope — the grant never widens federated",
       %{grant_ws: grant_ws, grant_proj: grant_proj} do
    user = register_user()
    raw = owned_token!(user)
    # A LIVE, ACTIVE grant covering the OTHER workspace + dataset + type. If
    # federated folded grants (it does not, by design), this would surface
    # "grant-hit"; it must not.
    bind_grant!(grant_ws, user, %{
      project_id: grant_proj.id,
      dataset: @ds,
      type: "post"
    })

    titles = federated_titles(raw)

    # non-vacuous: the Default-scope doc proves the search actually ran
    assert "#{@term} default" in titles
    # DENY: the grant-covered other-workspace doc is never widened in
    refute "#{@term} granted-workspace secret" in titles
  end
end
