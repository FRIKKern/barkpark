defmodule BarkparkWeb.BulldocsBpmlWriteParityTest do
  @moduledoc """
  What a BPML sync answers a token writing where it lives, through the HTTP
  door only, so the same rows run on any head:

    * a token pinned to its home whose permission does not include writing is
      refused writing there, naming its home or naming nothing, and nothing is
      written;
    * a token pinned to its home with a read-only seat there, holding admin
      permission, writes there;
    * a request naming no workspace writes in the pinned token's home, and in
      a workspace-less token's one seat.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.{Membership, Role, RolePermission}

  @ds "production"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp slug(name), do: "bpml-parity-#{name}-#{System.unique_integer([:positive])}"

  defp blocks(word),
    do: [
      %{"id" => "h", "type" => "heading", "level" => 2, "text" => "Parity #{word}"},
      %{"id" => "p", "type" => "paragraph", "content" => [t("Body #{word}.")]}
    ]

  defp tenant! do
    ws = TenancyFixtures.create_workspace!()
    {:ok, project} = Tenancy.create_project_with_dataset(ws, %{name: "bpml parity #{ws.slug}"})
    %{ws: ws, project: project}
  end

  defp token!(ws_id, perms) do
    raw = "bpml-parity-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bpml parity", @ds, perms, ws_id)
    {raw, token}
  end

  defp read_role!(ws_id) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "reader", workspace_id: ws_id}))
    perm = RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
    {:ok, _} = Repo.insert(perm)
    "reader"
  end

  # BPML for `slug`, printed by the pull of a throwaway `production` Paper.
  defp bpml_for!(slug, word) do
    source = slug("source")

    {:ok, _} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{"slug" => source, "blocks" => blocks(word)})
      )

    resp = get(build_conn(), "/papers/#{source}/source", %{"format" => "bpml"})
    assert resp.status == 200, resp.resp_body
    Repo.delete!(Content.get_paper(source))
    String.replace(resp.resp_body, source, slug)
  end

  defp sync(raw, slug, extra) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/plugins/bulldocs/papers/#{slug}/sync",
      Map.merge(%{"bpml" => bpml_for!(slug, "W"), "baseRev" => "0"}, extra)
    )
  end

  defp rows(slug) do
    Repo.all(
      from d in Barkpark.Content.Document,
        where: d.type == "paper" and d.doc_id == ^slug,
        select: d.workspace_id
    )
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "a token pinned to its home without write permission is refused writing there" do
    h = tenant!()
    {raw, _token} = token!(h.ws.id, ["read"])

    for named <- [%{}, %{"workspace_id" => h.ws.id, "project_id" => h.project.id}] do
      slug = slug("read")
      resp = sync(raw, slug, named)
      assert resp.status == 401, resp.resp_body
      assert rows(slug) == []
    end
  end

  test "a token pinned to its home with a read-only seat, holding admin, writes there" do
    h = tenant!()
    {raw, token} = token!(h.ws.id, ["admin"])
    role = read_role!(h.ws.id)

    Repo.update_all(from(m in Membership, where: m.principal_id == ^token.id), set: [role: role])
    assert Tenancy.Auth.authorize(token, h.ws.id, :write) != :ok

    slug = slug("seat-read")
    assert json_response(sync(raw, slug, %{}), 200)["created"]
    assert rows(slug) == [h.ws.id]
  end

  test "a request naming no workspace writes in the pinned token's home" do
    h = tenant!()
    {raw, _token} = token!(h.ws.id, ["admin"])
    slug = slug("pinned")
    assert json_response(sync(raw, slug, %{}), 200)["created"]
    assert rows(slug) == [h.ws.id]
  end

  test "a request naming no workspace writes in a workspace-less token's one seat" do
    a = tenant!()
    {raw, token} = token!(nil, ["admin"])
    {:ok, _} = Tenancy.Auth.create_membership(a.ws.id, token.id, "member")
    slug = slug("seat")
    assert json_response(sync(raw, slug, %{}), 200)["created"]
    assert rows(slug) == [a.ws.id]
  end
end
