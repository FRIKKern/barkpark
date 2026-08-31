defmodule BarkparkWeb.AppTokenCrossWorkspaceListTest do
  @moduledoc """
  `task-71787769f1d03e51` — the app-token ENUMERATE selector must not reach
  another workspace's credentials either.

  ## The pattern this closes: the by-id door got scoped, the LIST door did not

  `task-ea8cae3258ea4bd3` threaded a required `actor` through BOTH revoke
  selectors — `Auth.revoke_app_tokens_for_email/2` and
  `Auth.revoke_app_token_by_id/2` — and stated the rule in the query layer so
  "the unscoped form is no longer spellable". `Auth.list_app_tokens/1`, the
  third selector on the SAME controller, took only `opts` and no actor at all.

  That asymmetry is not an accident of this module, it is the shape of the
  class: a BY-ID lookup naturally has the id and the caller in hand, so scoping
  it reads as authorization. A LIST takes FILTERS, and "which filters" reads as
  a query question — so the list door is where authorization looks like
  configuration. `list_app_tokens/1` took an `:email` keyword and nothing else,
  and nobody noticed that the missing keyword was the caller.

  ## What the unscoped list handed out, concretely

  `GET /v1/auth/app-tokens?email=<addr>` answered, for an ARBITRARY address,
  whether it holds a live app token anywhere on the instance — and because
  `filtered? == true` suppresses the label redaction, it answered with the
  UNREDACTED `label`, plus `workspace_id` (which tenants that user belongs to),
  `permissions`, `dataset`, `id` and the dates.

  That is exactly the disclosure the revoke sibling was rewritten to REFUSE.
  `revoke_app_tokens_for_email/2`'s docstring justifies its bare count in these
  words: "a 403 here would confirm that the address holds a live token
  somewhere on the instance, which is the disclosure the route already refuses
  to make". The route did not refuse it — one HTTP GET away on the same
  controller, `index/2` granted it. A refusal a neighbour grants is not a
  refusal.

  ## SCOPE: the `?email=` arm ONLY, and the last describe block pins that

  The unfiltered sweep is deliberately NOT scoped by this change, and there is
  a test asserting it still returns another workspace's rows. That is not an
  oversight being documented — it is the boundary being held. The chartered
  defect is that a caller can name a SPECIFIC address and be told yes or no;
  an unfiltered sweep cannot probe an address (labels are withheld), so it
  discloses an inventory rather than answering a question about a person.
  Whether an admin should see that inventory is a real policy question, it is
  open as `task-aa07355fa8a53355`, and this change does not settle it.

  ## Why the fixture stands up TWO workspaces

  The legacy suite mints everything into the seeded Default workspace, so a
  reader that forgot to thread scope returns the same rows either way and the
  boundary is untested by construction. Every test below crosses a real seam.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @app_permissions ["read", "write", "chat"]

  setup :reset_rate_limiter!

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    admin_a = raw("adm-a")
    admin_b = raw("adm-b")

    # `create_token/5` writes the principal's membership in the bound workspace
    # with the role derived from permissions — so each of these is an ADMIN
    # MEMBER of exactly one workspace and a stranger to the other.
    {:ok, _} = Auth.create_token(admin_a, "adm-a", @dataset, ["read", "write", "admin"], ws_a.id)
    {:ok, _} = Auth.create_token(admin_b, "adm-b", @dataset, ["read", "write", "admin"], ws_b.id)

    %{ws_a: ws_a, ws_b: ws_b, admin_a: admin_a, admin_b: admin_b}
  end

  defp raw(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp email, do: "victim-#{System.unique_integer([:positive])}@example.com"

  # An app token as the mint would write it: `app:<email>` label, member-shaped
  # permission set, bound to one workspace.
  defp app_token_in!(workspace, mail) do
    secret = raw("bpapp")

    {:ok, token} =
      Auth.create_token(secret, "app:" <> mail, @dataset, @app_permissions, workspace.id)

    {secret, token}
  end

  defp json_conn(bearer) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  describe "?email= is confined to workspaces the caller administers" do
    test "an admin of A learns NOTHING about an address whose token lives in B",
         %{ws_b: ws_b, admin_a: admin_a} do
      mail = email()
      {_secret, row} = app_token_in!(ws_b, mail)

      conn = json_conn(admin_a) |> get("/v1/auth/app-tokens?email=#{mail}")

      # Status pinned EXPLICITLY, not merely implied by json_response/2: a bare
      # "no foreign ids present" refute would also pass on an error page or on
      # an empty list produced by some unrelated cause. The refusal has to be a
      # 200 with an empty set, because that is what makes it indistinguishable
      # from the address existing nowhere.
      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["tokens"] == [],
             "workspace A's admin enumerated #{length(body["tokens"])} of workspace B's tokens"

      # Every field the row would have leaked, named individually so a partial
      # regression cannot hide behind an empty-list assertion that stopped
      # being reached.
      serialized = Jason.encode!(body)

      refute String.contains?(serialized, mail),
             "the foreign address was echoed back — the existence oracle survives"

      refute String.contains?(serialized, row.id),
             "a foreign row id leaked (the revoke-by-id selector's input)"

      refute String.contains?(serialized, ws_b.id),
             "a foreign workspace_id leaked — tenant discovery"

      refute String.contains?(serialized, "app:" <> mail),
             "the unredacted label leaked"
    end

    test "the answer is BYTE-IDENTICAL to one for an address that exists nowhere",
         %{ws_b: ws_b, admin_a: admin_a} do
      provisioned = email()
      {_secret, _row} = app_token_in!(ws_b, provisioned)
      absent = email()

      foreign = json_conn(admin_a) |> get("/v1/auth/app-tokens?email=#{provisioned}")
      missing = json_conn(admin_a) |> get("/v1/auth/app-tokens?email=#{absent}")

      assert foreign.status == 200
      assert missing.status == 200

      # No status-code difference and no body difference: nothing in the
      # response distinguishes "provisioned in a workspace you do not
      # administer" from "never heard of it". That IS the denial shape the
      # revoke sibling documents — foreign rows are simply absent, never a 403
      # that would confirm the address.
      assert foreign.resp_body == missing.resp_body,
             "a provisioned foreign address is distinguishable from an unknown one"
    end

    test "THE LEGITIMATE ARM: an admin still enumerates its OWN workspace, label and all",
         %{ws_a: ws_a, admin_a: admin_a} do
      mail = email()
      {_secret, row} = app_token_in!(ws_a, mail)

      conn = json_conn(admin_a) |> get("/v1/auth/app-tokens?email=#{mail}")
      assert conn.status == 200
      body = json_response(conn, 200)

      assert body["label_redacted"] == false
      assert [listed] = body["tokens"]
      assert listed["id"] == row.id
      assert listed["label"] == "app:" <> mail
      assert listed["workspace_id"] == ws_a.id
    end

    test "the split is per-row: A's copy is listed, B's is not, in ONE call",
         %{ws_a: ws_a, ws_b: ws_b, admin_a: admin_a} do
      mail = email()
      {_mine, mine_row} = app_token_in!(ws_a, mail)
      {_theirs, theirs_row} = app_token_in!(ws_b, mail)

      conn = json_conn(admin_a) |> get("/v1/auth/app-tokens?email=#{mail}")
      assert conn.status == 200

      ids = conn |> json_response(200) |> Map.fetch!("tokens") |> Enum.map(& &1["id"])

      # The POSITIVE control sits in the SAME call as the refute: one request,
      # one address, one row kept and one dropped. A stub that emptied the list
      # would red on the assert, so the refute cannot pass vacuously.
      assert mine_row.id in ids
      refute theirs_row.id in ids
    end

    test "B's own admin still sees B's row — the row is not orphaned",
         %{ws_b: ws_b, admin_b: admin_b} do
      mail = email()
      {_secret, row} = app_token_in!(ws_b, mail)

      conn = json_conn(admin_b) |> get("/v1/auth/app-tokens?email=#{mail}")
      assert conn.status == 200

      assert conn |> json_response(200) |> Map.fetch!("tokens") |> Enum.map(& &1["id"]) ==
               [row.id]
    end
  end

  describe "the UNFILTERED sweep is DELIBERATELY left alone" do
    test "an admin of A still sees B's rows unfiltered — task-aa07355fa8a53355 is NOT closed here",
         %{ws_a: ws_a, ws_b: ws_b, admin_a: admin_a} do
      # THE SCOPE BOUNDARY OF THIS CHANGE, asserted rather than described, so
      # nobody has to read a PR body to know what was and was not decided.
      #
      # The chartered defect is the `?email=` arm: it lets a caller name a
      # SPECIFIC address and be told yes or no. The unfiltered sweep cannot
      # probe an address — labels are withheld — so it discloses an inventory
      # rather than answering a question about a person. Whether an admin
      # should see that inventory is a genuine policy question with an argument
      # on each side, it is open as `task-aa07355fa8a53355`, and settling it as
      # a side effect of a security fix nobody reviewed as a policy decision is
      # how these come back. So this test PINS the current behaviour: if a
      # later change scopes the sweep, this test reds and forces that decision
      # to be made deliberately, by aa073's owner.
      {_mine, mine_row} = app_token_in!(ws_a, email())
      {_theirs, theirs_row} = app_token_in!(ws_b, email())

      conn = json_conn(admin_a) |> get("/v1/auth/app-tokens")
      assert conn.status == 200
      body = json_response(conn, 200)

      ids = Enum.map(body["tokens"], & &1["id"])
      assert mine_row.id in ids

      assert theirs_row.id in ids,
             "the unfiltered sweep was scoped too — that decides task-aa07355fa8a53355 " <>
               "as a side effect, which this change deliberately does not do"

      # The redaction is what keeps the sweep from being a user directory, and
      # it is untouched. It is a SECOND, independent guard — it hides addresses
      # and says nothing about ids, workspace ids or permission sets.
      assert body["label_redacted"] == true
      assert Enum.all?(body["tokens"], &is_nil(&1["label"]))
    end
  end

  describe "the predicate is membership, and it has no instance-level escape hatch" do
    test "an admin member of BOTH workspaces still gets both rows from ?email=",
         %{ws_a: ws_a, ws_b: ws_b} do
      # THE POSITIVE CONTROL that rules out a vacuous green: the scoping is not
      # "the filtered arm returns nothing now". A caller who genuinely
      # administers both workspaces sees the rows in both, in ONE call, for the
      # SAME address — so the empty answers above are the predicate working,
      # not the query being broken.
      #
      # It also fixes the meaning of "instance-wide operator" on this arm.
      # `Auth.has_permission?/2` — the route's gate, and the same test
      # `Plugs.RequireAdmin` applies — is a flat read of the token's global
      # `permissions[]` with NO membership requirement, and it grants reach to
      # the ROUTE. `workspace_admin?/2` is `membership_role/2 in ~w(owner
      # admin)` and grants ROWS. So an `admin`-permissioned token holding zero
      # memberships passes the gate and administers nothing: on `?email=` that
      # is the ratified posture of the write twin, which hands such a caller
      # `revoked_count: 0`. On the unfiltered sweep it would empty that
      # operator's inventory, which is why the sweep is left alone.
      mail = email()
      {_a_secret, a_row} = app_token_in!(ws_a, mail)
      {_b_secret, b_row} = app_token_in!(ws_b, mail)

      operator = raw("operator")
      {:ok, op_token} = Auth.create_token(operator, "operator", @dataset, ["admin"], ws_a.id)
      {:ok, _} = TenancyAuth.create_membership(ws_b.id, op_token.id, "admin")

      conn = json_conn(operator) |> get("/v1/auth/app-tokens?email=#{mail}")
      assert conn.status == 200

      ids =
        conn
        |> json_response(200)
        |> Map.fetch!("tokens")
        |> Enum.map(& &1["id"])

      assert a_row.id in ids
      assert b_row.id in ids, "an admin member of BOTH workspaces lost one workspace's rows"
    end

    test "a row with a NULL workspace_id is administrable by NOBODY and is absent from ?email=",
         %{admin_a: admin_a, admin_b: admin_b} do
      # `create_token/5` falls back to the default workspace, so an unbound row
      # has to be written directly — which is exactly why fail-closed matters:
      # nothing guarantees every historical row carries a workspace.
      mail = email()

      {:ok, orphan} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw("bpapp-orphan")),
          label: "app:" <> mail,
          dataset: @dataset,
          permissions: @app_permissions,
          kind: "api"
        })
        |> Repo.insert()

      assert is_nil(orphan.workspace_id), "fixture did not produce an unbound row"

      for bearer <- [admin_a, admin_b] do
        conn = json_conn(bearer) |> get("/v1/auth/app-tokens?email=#{mail}")
        assert conn.status == 200

        assert json_response(conn, 200)["tokens"] == [],
               "an unbound app token was listed — the predicate is not fail-closed"
      end
    end
  end
end
