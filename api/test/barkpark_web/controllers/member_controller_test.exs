defmodule BarkparkWeb.MemberControllerTest do
  @moduledoc """
  The workspace roster surface: `/w/:ws/p/:proj/v1/members` (+ the token
  inventory beside it).

  What these tests are FOR. The endpoints exist because an instance owner could
  not seat their own user account in a workspace their token had created — so
  the suite pins the seating path itself, and then the two rails that make an
  admin surface safe to hand somebody:

    * **Last-owner protection.** Demoting or removing the workspace's last
      owner is refused. Without this, one wrong call leaves a workspace nobody
      can ever administer again (no recovery short of DB access). Both the
      demote and the remove leg are pinned, AND the pass-through case (a second
      owner exists) is pinned too — a rail that refuses everything would pass a
      one-sided test while being useless.
    * **Cross-tenant isolation.** An admin of A must not read, re-role, remove
      or REVOKE anything in B. The oracle is that B's seat is indistinguishable
      from a seat that does not exist (404), and — the part a status assertion
      alone would miss — that B's rows are still intact afterwards.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Members
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  # A denial of the CREDENTIAL, either shape. The scoped read pipeline resolves
  # bearers softly, so a rejected token continues as anonymous and is refused on
  # membership (403) rather than on authentication (401).
  @denials [401, 403]

  setup do
    %{ws: ws, project: project, admin_raw: admin_raw} = workspace_with_admin("a")

    %{ws: other_ws, project: other_project, admin_raw: other_admin_raw} =
      workspace_with_admin("b")

    %{
      ws: ws,
      project: project,
      admin_raw: admin_raw,
      other_ws: other_ws,
      other_project: other_project,
      other_admin_raw: other_admin_raw
    }
  end

  # A workspace with a project and an api_token holding an ADMIN seat — the
  # shape `:scoped_admin` demands (authority is the membership ROLE, not the
  # token's global permissions).
  defp workspace_with_admin(tag) do
    ws = create_workspace!("roster-#{tag}-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    raw = "roster-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "roster-#{tag}", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")
    %{ws: ws, project: project, admin_raw: raw, token: token}
  end

  defp req(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp base(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1"

  defp seat_user!(ws, email, role) do
    {:ok, member} = Members.add_user_member(ws.id, email, role)
    member
  end

  defp unique_email(tag \\ "person"),
    do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seats(ws_id),
    do: Repo.all(from(m in Membership, where: m.workspace_id == ^ws_id))

  describe "the admin gate" do
    # OBSERVED SHAPE, not a preference: a bearer-less request is denied by the
    # workspace-ROLE gate (403 "token lacks required permission"), not by
    # RequireToken (401). That is the whole `:scoped_admin` pipeline's existing
    # behaviour — every route on it answers the same way — so this suite pins
    # what the pipeline does rather than asserting a 401 it has never returned.
    # The 401-vs-403 nit for anonymous callers belongs to the pipeline, not to
    # this endpoint, and is reported separately.
    test "no bearer → denied (403 from the role gate, per the pipeline)", %{
      ws: ws,
      project: project
    } do
      body = build_conn() |> get("#{base(ws, project)}/members") |> json_response(403)
      assert body["error"]["code"] == "forbidden"
    end

    test "a MEMBER seat cannot administer the roster, even holding global admin perms",
         %{ws: ws, project: project} do
      raw = "mere-member-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "mere-member", @dataset, ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member", "api_token")

      # The whole point of the :scoped_admin gate: authority is the membership
      # ROLE. A globally-privileged token seated as `member` is not an admin here.
      assert req(raw) |> get("#{base(ws, project)}/members") |> json_response(403)
    end
  end

  describe "roster (index)" do
    test "lists BOTH human and token seats, with identities and never a secret",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("rostered")
      seat_user!(ws, email, "member")

      body = req(admin_raw) |> get("#{base(ws, project)}/members") |> json_response(200)
      members = body["members"]

      user_row = Enum.find(members, &(&1["principal_type"] == "user"))
      token_row = Enum.find(members, &(&1["principal_type"] == "api_token"))

      assert user_row["identity"] == email
      assert user_row["role"] == "member"
      # The token seat from the fixture — the roster answers "who can reach
      # this workspace", which is not answerable from humans alone.
      assert token_row["identity"] == "roster-a"
      assert token_row["role"] == "admin"

      # No secret material may ride along in any row.
      refute body |> Jason.encode!() |> String.contains?("token_hash")
      refute body |> Jason.encode!() |> String.contains?(admin_raw)
    end

    test "owners sort before admins before members", %{
      ws: ws,
      project: project,
      admin_raw: admin_raw
    } do
      seat_user!(ws, unique_email("zowner"), "owner")
      seat_user!(ws, unique_email("amember"), "member")

      roles =
        req(admin_raw)
        |> get("#{base(ws, project)}/members")
        |> json_response(200)
        |> Map.fetch!("members")
        |> Enum.map(& &1["role"])

      assert roles == Enum.sort_by(roles, &%{"owner" => 0, "admin" => 1, "member" => 2}[&1])
    end
  end

  describe "seating a human (create)" do
    test "seats by e-mail and writes a user-principal membership row",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("seated")

      body =
        req(admin_raw)
        |> post("#{base(ws, project)}/members", Jason.encode!(%{email: email, role: "admin"}))
        |> json_response(201)

      assert body["member"]["identity"] == email
      assert body["member"]["role"] == "admin"

      # The row itself is the deliverable — a 201 that wrote nothing would pass
      # a body-only assertion.
      row =
        Repo.one(
          from(m in Membership,
            where:
              m.workspace_id == ^ws.id and m.principal_type == "user" and
                m.principal_id == ^body["member"]["principal_id"]
          )
        )

      assert row.role == "admin"
    end

    test "defaults to the member role", %{ws: ws, project: project, admin_raw: admin_raw} do
      body =
        req(admin_raw)
        |> post("#{base(ws, project)}/members", Jason.encode!(%{email: unique_email()}))
        |> json_response(201)

      assert body["member"]["role"] == "member"
    end

    test "seating the same person twice is a 409, never a silent re-role",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("twice")
      seat_user!(ws, email, "member")

      body =
        req(admin_raw)
        |> post("#{base(ws, project)}/members", Jason.encode!(%{email: email, role: "owner"}))
        |> json_response(409)

      assert body["error"]["code"] == "already_member"

      # And the role really did NOT change — the danger of a silent re-role is
      # that it is a privilege change wearing an "add" costume.
      assert [%Membership{role: "member"}] =
               Repo.all(
                 from(m in Membership,
                   where: m.workspace_id == ^ws.id and m.principal_type == "user"
                 )
               )
    end

    test "a blank e-mail is a 422", %{ws: ws, project: project, admin_raw: admin_raw} do
      assert req(admin_raw)
             |> post("#{base(ws, project)}/members", Jason.encode!(%{email: "   "}))
             |> json_response(422)
    end
  end

  describe "role changes (update) — last-owner rail" do
    test "changes a role by e-mail", %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("promotable")
      seat_user!(ws, email, "member")

      body =
        req(admin_raw)
        |> patch("#{base(ws, project)}/members/#{email}", Jason.encode!(%{role: "admin"}))
        |> json_response(200)

      assert body["member"]["role"] == "admin"
    end

    test "REFUSES to demote the last owner", %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("lastowner")
      seat_user!(ws, email, "owner")

      body =
        req(admin_raw)
        |> patch("#{base(ws, project)}/members/#{email}", Jason.encode!(%{role: "member"}))
        |> json_response(409)

      assert body["error"]["code"] == "last_owner"
      assert %Membership{role: "owner"} = owner_row(ws.id)
    end

    test "ALLOWS demoting an owner when another owner remains — the rail is not a wall",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      first = unique_email("owner-one")
      second = unique_email("owner-two")
      seat_user!(ws, first, "owner")
      seat_user!(ws, second, "owner")

      assert req(admin_raw)
             |> patch("#{base(ws, project)}/members/#{first}", Jason.encode!(%{role: "member"}))
             |> json_response(200)
    end

    test "an unknown role is a 422 from the changeset", %{
      ws: ws,
      project: project,
      admin_raw: admin_raw
    } do
      email = unique_email("typo")
      seat_user!(ws, email, "member")

      assert req(admin_raw)
             |> patch("#{base(ws, project)}/members/#{email}", Jason.encode!(%{role: "adnim"}))
             |> json_response(422)
    end

    test "an e-mail nobody holds is a 404", %{ws: ws, project: project, admin_raw: admin_raw} do
      assert req(admin_raw)
             |> patch(
               "#{base(ws, project)}/members/nobody-#{System.unique_integer([:positive])}@example.com",
               Jason.encode!(%{role: "admin"})
             )
             |> json_response(404)
    end
  end

  describe "removal (delete) — last-owner rail" do
    test "removes a seat", %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("removable")
      seat_user!(ws, email, "member")
      before = length(seats(ws.id))

      assert req(admin_raw)
             |> delete("#{base(ws, project)}/members/#{email}")
             |> json_response(200)

      assert length(seats(ws.id)) == before - 1
    end

    test "REFUSES to remove the last owner, and the seat survives",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      email = unique_email("solo-owner")
      seat_user!(ws, email, "owner")

      body =
        req(admin_raw) |> delete("#{base(ws, project)}/members/#{email}") |> json_response(409)

      assert body["error"]["code"] == "last_owner"
      assert %Membership{role: "owner"} = owner_row(ws.id)
    end
  end

  describe "cross-tenant isolation" do
    test "an admin of A cannot see B's roster", %{
      ws: ws,
      project: project,
      other_ws: other_ws,
      other_project: other_project,
      admin_raw: admin_raw
    } do
      seat_user!(other_ws, unique_email("b-only"), "member")

      # A's admin against B's scope: the workspace-role gate denies.
      assert req(admin_raw)
             |> get("#{base(other_ws, other_project)}/members")
             |> json_response(403)

      # …and A's own roster does not contain B's people.
      identities =
        req(admin_raw)
        |> get("#{base(ws, project)}/members")
        |> json_response(200)
        |> Map.fetch!("members")
        |> Enum.map(& &1["identity"])

      refute Enum.any?(identities, &(&1 && String.starts_with?(&1, "b-only")))
    end

    test "a principal id from B is a 404 in A's scope — and B's seat survives", %{
      ws: ws,
      project: project,
      other_ws: other_ws,
      admin_raw: admin_raw
    } do
      b_member = seat_user!(other_ws, unique_email("b-seat"), "member")
      before = length(seats(other_ws.id))

      assert req(admin_raw)
             |> delete("#{base(ws, project)}/members/#{b_member.principal_id}")
             |> json_response(404)

      # The status alone would not catch a delete that 404s AFTER deleting.
      assert length(seats(other_ws.id)) == before
    end
  end

  describe "token inventory" do
    test "lists the workspace's tokens without secrets", %{
      ws: ws,
      project: project,
      admin_raw: admin_raw
    } do
      body = req(admin_raw) |> get("#{base(ws, project)}/tokens") |> json_response(200)

      assert [row] = body["tokens"]
      assert row["label"] == "roster-a"
      assert row["role"] == "admin"
      refute body |> Jason.encode!() |> String.contains?(admin_raw)
      refute body |> Jason.encode!() |> String.contains?("token_hash")
    end

    # THE INVENTORY IS THE ENUMERATION ORACLE, so its tenancy rail needs its own
    # pin. The revoke leg below is fenced by `Members.token_member?/2` and has a
    # test; the LIST leg is fenced by a different mechanism — the workspace id
    # comes from `conn.assigns[:current_workspace]` and the query joins
    # membership on it — and nothing pinned it. A regression that swapped the
    # join for an unscoped `Repo.all(ApiToken)` would keep every other test in
    # this block green while handing A's admin the label, permissions and id of
    # every credential on the instance, which is exactly the id `token revoke`
    # takes. Both directions are asserted: A cannot READ B's scope, and A's OWN
    # scope does not contain B's rows.
    test "the token inventory does not cross tenants — neither by scope nor by leak", %{
      ws: ws,
      project: project,
      other_ws: other_ws,
      other_project: other_project,
      admin_raw: admin_raw
    } do
      b_raw = "b-inventory-#{System.unique_integer([:positive])}"
      {:ok, b_token} = Auth.create_token(b_raw, "b-inventory", @dataset, ["read"])
      {:ok, _} = TenancyAuth.create_membership(other_ws.id, b_token.id, "member", "api_token")

      # A's admin reaching into B's scope is refused by the workspace-role gate.
      assert req(admin_raw)
             |> get("#{base(other_ws, other_project)}/tokens")
             |> json_response(403)

      # …and B's credential is absent from A's own inventory. Asserted on the
      # id we just created rather than on the row COUNT: every agent shares one
      # test database, so a count is another agent's row away from lying.
      body = req(admin_raw) |> get("#{base(ws, project)}/tokens") |> json_response(200)

      refute b_token.id in Enum.map(body["tokens"], & &1["id"]),
             "workspace A's token inventory must not carry a credential seated only in B — " <>
               "this listing is what feeds `bp token revoke <id>`"

      refute body |> Jason.encode!() |> String.contains?(b_raw)
    end

    test "revoking a token that holds a seat here stamps revoked_at", %{
      ws: ws,
      project: project,
      admin_raw: admin_raw
    } do
      victim_raw = "victim-#{System.unique_integer([:positive])}"
      {:ok, victim} = Auth.create_token(victim_raw, "victim", @dataset, ["read"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, victim.id, "member", "api_token")

      assert req(admin_raw)
             |> delete("#{base(ws, project)}/tokens/#{victim.id}")
             |> json_response(200)

      assert Repo.get(Barkpark.Auth.ApiToken, victim.id).revoked_at
    end

    test "an admin of A CANNOT revoke B's token — 404, and B's token stays live", %{
      ws: ws,
      project: project,
      other_ws: other_ws,
      admin_raw: admin_raw
    } do
      b_raw = "b-token-#{System.unique_integer([:positive])}"
      {:ok, b_token} = Auth.create_token(b_raw, "b-token", @dataset, ["read"])
      {:ok, _} = TenancyAuth.create_membership(other_ws.id, b_token.id, "member", "api_token")

      assert req(admin_raw)
             |> delete("#{base(ws, project)}/tokens/#{b_token.id}")
             |> json_response(404)

      # The rail is only real if the credential is still usable afterwards.
      refute Repo.get(Barkpark.Auth.ApiToken, b_token.id).revoked_at
    end

    test "a garbage token id is a clean 404, never a 500", %{
      ws: ws,
      project: project,
      admin_raw: admin_raw
    } do
      assert req(admin_raw)
             |> delete("#{base(ws, project)}/tokens/not-a-uuid")
             |> json_response(404)
    end

    # ssw8 — THE REVOKE IS ONLY REAL IF THE CREDENTIAL STOPS WORKING.
    #
    # Every other test in this block asserts a COLUMN: `revoked_at` is stamped,
    # or it is not. That is one inference short of the fact a credential-hygiene
    # fix depends on. The control plane's site-delete path
    # (`BarkparkCloud.Registry.revoke_site_read_token/1`) drives exactly the pair
    # exercised here — the scoped mint `POST /w/:ws/p/:proj/v1/tokens` that
    # `mint_public_read_token/5` calls, then the scoped revoke
    # `DELETE /w/:ws/p/:proj/v1/tokens/:id` — so this is the box-side half of
    # "delete a site, its read token no longer authenticates".
    #
    # The oracle is the AUTH outcome (401), not the body: what a `public-read`
    # token is allowed to SEE is `Plugs.PublicRead`'s business and varies with
    # schema visibility, while "this bearer is no longer a credential" does not.
    # The before-assertion is not decoration — without it a route that 401s for
    # some unrelated reason would make the after-assertion vacuously green.
    test "a revoked site-read token STOPS AUTHENTICATING on the scoped read its site builds with",
         %{ws: ws, project: project, admin_raw: admin_raw} do
      minted =
        req(admin_raw)
        |> post(
          "#{base(ws, project)}/tokens",
          Jason.encode!(%{
            label: "site-read-proof-#{System.unique_integer([:positive])}",
            permissions: ["public-read"],
            dataset: @dataset
          })
        )
        |> json_response(201)

      raw = minted["token"]
      read_path = "#{base(ws, project)}/data/query/#{@dataset}/post"

      before_status = req(raw) |> get(read_path) |> Map.fetch!(:status)

      refute before_status in @denials,
             "the freshly minted token must be ACCEPTED as a credential before the revoke, or " <>
               "the assertion below proves nothing (got #{before_status})"

      assert req(admin_raw)
             |> delete("#{base(ws, project)}/tokens/#{minted["id"]}")
             |> json_response(200)

      after_conn = req(raw) |> get(read_path)

      assert after_conn.status in @denials,
             "a revoked site-read token must no longer reach this workspace's content — this is " <>
               "the whole point of revoking it when its site is deleted (got #{after_conn.status})"

      # WHY 403 AND NOT 401, stated so nobody "corrects" the assertion into a
      # 401-only one and reds it: the scoped read pipeline resolves the bearer
      # SOFTLY (`Plugs.OptionalToken`). A revoked token is simply not assigned,
      # so the request continues as ANONYMOUS and `ResolveWorkspace` refuses it
      # on membership. Either shape is a denial of the credential, which is the
      # fact being pinned; the exact code is that pipeline's business.
      assert Jason.decode!(after_conn.resp_body)["error"]["code"] in ~w(unauthorized forbidden)
    end
  end

  defp owner_row(ws_id) do
    Repo.one(
      from(m in Membership,
        where: m.workspace_id == ^ws_id and m.principal_type == "user" and m.role == "owner"
      )
    )
  end
end
