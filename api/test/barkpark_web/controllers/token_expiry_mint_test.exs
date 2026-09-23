defmodule BarkparkWeb.TokenExpiryMintTest do
  @moduledoc """
  task-a0f8cfd7f4800236 — mint-time token expiry policy, over HTTP, on EVERY
  mint route that writes an `api_tokens` row.

    * DEFAULT NIL (as shipped) — each route mints exactly the `expires_at` it
      minted before the policy existed: nil for the scoped read-token mint,
      fleet support, chat, app and playground tokens; 30 days for the PAT
      self-mint; 7 days for the share-edit mint.
    * DEFAULT CONFIGURED — a request-less mint of that kind carries the
      default; app tokens (`class: :app`) and paths with their own built-in
      horizon (PAT, share-edit) are unchanged; rows minted earlier are untouched.
    * MAX AGE — a requested expiry over the kind's max is 422 NAMING the max
      and no row is written (never clamped).
    * NO-EXPIRY OPT-OUT — instance-admin only, 403 otherwise, audited.

  async: false — the configured-default arms put_env
  `:token_default_expiry_days`, which every mint reads.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Accounts, Auth, Repo, Sharing, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @day 86_400

  setup do
    prior_default = Application.get_env(:barkpark, :token_default_expiry_days)
    prior_shares = Application.get_env(:barkpark, :shares)
    prior_shares_env = Application.get_env(:barkpark, :shares_env)

    on_exit(fn ->
      restore(:token_default_expiry_days, prior_default)
      restore(:shares, prior_shares)
      restore(:shares_env, prior_shares_env)
    end)

    # PRECONDITION: the shipped default is nil for both kinds. Every "as
    # today" arm below is only a proof if this holds.
    assert Auth.TokenExpiry.default_days(:api) == nil
    assert Auth.TokenExpiry.default_days(:share) == nil

    {:ok, ws} = Tenancy.create_workspace(%{slug: uniq("exp-ws"), name: "Expiry WS"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    # Workspace ADMIN holding the flat instance "admin" permission.
    admin_raw = uniq("exp-admin")

    {:ok, admin_tok} =
      Auth.create_token(admin_raw, "exp-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    # Workspace ADMIN (passes the scoped-admin route gate) WITHOUT the flat
    # "admin" permission — the principal the opt-out must refuse.
    ws_admin_raw = uniq("exp-wsadmin")
    {:ok, ws_admin_tok} = Auth.create_token(ws_admin_raw, "exp-wsadmin", @dataset, ["read"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, ws_admin_tok.id, "admin")

    # Default-workspace instance admin (fleet support / share / app / playground).
    root_raw = uniq("exp-root")

    {:ok, _} =
      Auth.create_token(
        root_raw,
        "exp-root",
        @dataset,
        ["read", "write", "admin"],
        default_workspace_id!()
      )

    %{ws: ws, admin_raw: admin_raw, ws_admin_raw: ws_admin_raw, root_raw: root_raw}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp configure_default(map), do: Application.put_env(:barkpark, :token_default_expiry_days, map)

  defp bearer(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp row!(raw), do: Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw))

  defp token_count, do: Repo.aggregate(ApiToken, :count)

  defp days_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second) / @day

  # ── the seven mint routes ────────────────────────────────────────────────

  defp mint_read_token(ws, raw, body) do
    bearer(raw) |> post("/w/#{ws.slug}/p/default/v1/tokens", Jason.encode!(body))
  end

  defp mint_fleet_support(raw),
    do: bearer(raw) |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: uniq("box")}))

  defp mint_chat(ws, raw),
    do:
      bearer(raw)
      |> post("/w/#{ws.slug}/p/default/v1/chat/tokens", Jason.encode!(%{label: uniq("chat")}))

  defp mint_app(raw, ws),
    do:
      bearer(raw)
      |> post(
        "/v1/auth/app-tokens",
        Jason.encode!(%{email: "#{uniq("app")}@example.com", workspace: ws.slug})
      )

  defp mint_playground(raw), do: bearer(raw) |> post("/api/playground")

  defp mint_pat do
    ws = create_workspace!()
    user = register_user("#{uniq("pat")}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")

    {:ok, session_raw} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    bearer(session_raw) |> post("/v1/auth/tokens", Jason.encode!(%{name: uniq("cli")}))
  end

  defp mint_share(raw, body_extra \\ %{}) do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = "#{ws.slug}/#{proj.slug}/#{@dataset}"
    Application.put_env(:barkpark, :shares_env, [])
    {:ok, _} = Sharing.add_share("#{scope}:docs:edit")

    # The share mint is confined to a workspace ADMIN of the scope's workspace.
    {:ok, tok} = Auth.verify_token(raw)
    {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id, "admin")

    bearer(raw)
    |> post("/v1/shares/tokens", Map.merge(%{scope: scope, surfaces: "docs"}, body_extra))
  end

  defp raw_of(conn, status), do: json_response(conn, status)["token"]

  # ── criterion 0: default nil → every route mints as today ────────────────

  describe "default nil (as shipped): every mint route behaves exactly as today" do
    test "scoped read-token mint (public-read AND read): no expiry", %{ws: ws, admin_raw: raw} do
      for perms <- [["public-read"], ["read"]] do
        conn = mint_read_token(ws, raw, %{"label" => uniq("site"), "permissions" => perms})
        assert row!(raw_of(conn, 201)).expires_at == nil
      end
    end

    test "fleet support-token mint: no expiry", %{root_raw: raw} do
      assert row!(raw_of(mint_fleet_support(raw), 201)).expires_at == nil
    end

    test "chat-token mint: no expiry", %{ws: ws, admin_raw: raw} do
      assert row!(raw_of(mint_chat(ws, raw), 201)).expires_at == nil
    end

    test "app-token mint: no expiry", %{ws: ws, root_raw: raw} do
      assert row!(raw_of(mint_app(raw, ws), 201)).expires_at == nil
    end

    test "playground mint: no expiry", %{root_raw: raw} do
      assert row!(raw_of(mint_playground(raw), 201)).expires_at == nil
    end

    test "PAT self-mint: its own 30-day horizon" do
      tok = row!(raw_of(mint_pat(), 201))
      assert_in_delta days_from_now(tok.expires_at), 30, 0.01
    end

    test "share-edit mint: its own 7-day horizon", %{root_raw: raw} do
      tok = row!(raw_of(mint_share(raw), 201))
      assert_in_delta days_from_now(tok.expires_at), 7, 0.01
    end
  end

  # ── criterion 1: a configured default is carried; old rows untouched ────

  describe "a configured per-kind default" do
    test "a request-less read-token mint carries its kind's default; earlier rows are untouched",
         %{ws: ws, admin_raw: raw} do
      before_raw = raw_of(mint_read_token(ws, raw, %{"label" => uniq("old")}), 201)
      assert row!(before_raw).expires_at == nil

      configure_default(%{api: 90, share: 14})

      share_tok =
        row!(raw_of(mint_read_token(ws, raw, %{"label" => uniq("new-share")}), 201))

      api_tok =
        row!(
          raw_of(
            mint_read_token(ws, raw, %{"label" => uniq("new-api"), "permissions" => ["read"]}),
            201
          )
        )

      assert_in_delta days_from_now(share_tok.expires_at), 14, 0.01
      assert_in_delta days_from_now(api_tok.expires_at), 90, 0.01

      # Existing tokens are never touched.
      assert row!(before_raw).expires_at == nil
    end

    test "fleet support tokens carry the api default", %{root_raw: raw} do
      configure_default(%{api: 90, share: nil})
      tok = row!(raw_of(mint_fleet_support(raw), 201))
      assert_in_delta days_from_now(tok.expires_at), 90, 0.01
    end

    test "app tokens stay unexpiring (class :app ignores the default)", %{ws: ws, root_raw: raw} do
      configure_default(%{api: 90, share: 14})
      assert row!(raw_of(mint_app(raw, ws), 201)).expires_at == nil
    end

    test "PAT and share-edit keep their built-in horizons", %{root_raw: raw} do
      configure_default(%{api: 90, share: 14})
      assert_in_delta days_from_now(row!(raw_of(mint_pat(), 201)).expires_at), 30, 0.01
      assert_in_delta days_from_now(row!(raw_of(mint_share(raw), 201)).expires_at), 7, 0.01
    end

    test "with a default set, the admin opt-out still mints an unexpiring token",
         %{ws: ws, admin_raw: raw} do
      configure_default(%{api: 90, share: 14})
      conn = mint_read_token(ws, raw, %{"label" => uniq("forever"), "no_expiry" => true})
      assert row!(raw_of(conn, 201)).expires_at == nil
    end
  end

  # ── criterion 2: max age refused, never clamped ──────────────────────────

  describe "a requested expiry over the kind's max age" do
    test "public-read (share, 30 days): 422 naming the max, no row written",
         %{ws: ws, admin_raw: raw} do
      at = DateTime.utc_now() |> DateTime.add(31 * @day) |> DateTime.to_iso8601()
      count = token_count()

      conn = mint_read_token(ws, raw, %{"label" => uniq("x"), "expires_at" => at})
      body = json_response(conn, 422)

      assert body["error"]["message"] =~ "max age of 30 days"
      assert body["error"]["details"] == %{"kind" => "share", "max_age_days" => 30}
      assert token_count() == count
    end

    test "read (api, 365 days): 422 naming the max, no row written", %{ws: ws, admin_raw: raw} do
      at = DateTime.utc_now() |> DateTime.add(366 * @day) |> DateTime.to_iso8601()
      count = token_count()

      conn =
        mint_read_token(ws, raw, %{
          "label" => uniq("x"),
          "permissions" => ["read"],
          "expires_at" => at
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "max age of 365 days"
      assert body["error"]["details"] == %{"kind" => "api", "max_age_days" => 365}
      assert token_count() == count
    end

    test "within the max: 201 carrying EXACTLY the requested expiry", %{ws: ws, admin_raw: raw} do
      at = DateTime.utc_now() |> DateTime.add(29 * @day) |> DateTime.truncate(:second)

      conn =
        mint_read_token(ws, raw, %{"label" => uniq("x"), "expires_at" => DateTime.to_iso8601(at)})

      assert row!(raw_of(conn, 201)).expires_at == at
    end

    test "a past expiry or a malformed body is 422, no row written", %{ws: ws, admin_raw: raw} do
      count = token_count()
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      for extra <- [
            %{"expires_at" => past},
            %{"expires_at" => "next tuesday"},
            %{"no_expiry" => "yes"},
            %{"expires_at" => past, "no_expiry" => true}
          ] do
        conn = mint_read_token(ws, raw, Map.put(extra, "label", uniq("x")))
        assert json_response(conn, 422)
      end

      assert token_count() == count
    end

    test "share-edit ttl over 30 days: 422 naming the max, no row written", %{root_raw: raw} do
      count = token_count()
      conn = mint_share(raw, %{ttl: 31 * @day})
      assert json_response(conn, 422)["error"]["message"] =~ "max age of 30 days"
      assert token_count() == count
    end
  end

  # ── criterion 2: the admin-only, audited no_expiry opt-out ───────────────

  describe "no_expiry opt-out" do
    test "an instance admin gets an unexpiring token and an audit row", %{
      ws: ws,
      admin_raw: raw
    } do
      conn = mint_read_token(ws, raw, %{"label" => uniq("forever"), "no_expiry" => true})
      tok = row!(raw_of(conn, 201))
      assert tok.expires_at == nil

      {:ok, actor} = Auth.verify_token(raw)

      assert [event] =
               Repo.all(
                 from(e in Event,
                   where: e.action == "token_no_expiry_opt_out" and e.subject == ^tok.id
                 )
               )

      assert event.category == "token"
      assert event.actor_id == actor.id
      assert event.metadata["kind"] == "share"
    end

    test "a workspace admin WITHOUT the admin permission is 403, no row, no audit", %{
      ws: ws,
      ws_admin_raw: raw
    } do
      count = token_count()

      audits =
        Repo.aggregate(from(e in Event, where: e.action == "token_no_expiry_opt_out"), :count)

      conn = mint_read_token(ws, raw, %{"label" => uniq("forever"), "no_expiry" => true})
      assert json_response(conn, 403)["error"]["message"] =~ "admin-only"
      assert token_count() == count

      assert Repo.aggregate(
               from(e in Event, where: e.action == "token_no_expiry_opt_out"),
               :count
             ) ==
               audits
    end

    test "CONTROL: the same workspace admin mints fine without the opt-out", %{
      ws: ws,
      ws_admin_raw: raw
    } do
      assert row!(raw_of(mint_read_token(ws, raw, %{"label" => uniq("ok")}), 201)).expires_at ==
               nil
    end
  end
end
