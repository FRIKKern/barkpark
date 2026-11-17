defmodule BarkparkWeb.DatasetBoundAdminWritesTest do
  @moduledoc """
  A dataset-bound admin token on the workspace-level admin writes: seat, re-role
  and remove a member, withdraw an invitation, revoke, rotate and mint a token,
  set and delete a run secret (scoped and flat).

  `:observe` (the default) lets each write through and records one audit row.
  `:enforce` refuses with 403 `dataset_not_bound` and changes nothing. A bound
  token revoking itself passes in both modes; an unbound admin token on the
  same seat writes everything in both modes and is never recorded.
  """
  use BarkparkWeb.ConnCase, async: false

  # Observe mode logs one line per write; keep them out of the test output.
  @moduletag :capture_log

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Auth, Repo, Secrets, Tenancy}
  alias Barkpark.Accounts
  alias Barkpark.AccountsFixtures
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Members
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Plugs.DatasetBoundAdminReads

  @admin ["read", "write", "admin"]
  @action "bound_token.admin_write"
  @label "bound writes"

  setup do
    ws = TenancyFixtures.create_workspace!()
    proj = TenancyFixtures.create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    on_exit(fn -> Application.put_env(:barkpark, :dataset_bound_admin_reads, previous) end)

    {:ok,
     ws: ws,
     base: "/w/#{ws.slug}/p/default",
     bound: token!(ws.id, dataset_bound: true),
     unbound: token!(ws.id, []),
     flat_bound: token!(nil, dataset_bound: true),
     flat_unbound: token!(nil, [])}
  end

  defp token!(ws_id, opts, perms \\ @admin) do
    raw = "bound-writes-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, @label, "production", perms, ws_id, opts)
    %{raw: raw, id: token.id}
  end

  defp enforce!, do: Application.put_env(:barkpark, :dataset_bound_admin_reads, :enforce)

  defp send_as(raw, method, path, body) do
    scoped_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> raw)
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp email, do: "bw-#{System.unique_integer([:positive])}@example.com"

  defp seated!(ws, email) do
    {:ok, _} = Members.add_user_member(ws.id, email, "member")
    email
  end

  defp role_of(ws, email) do
    with %{id: id} <- Accounts.get_user_by_email(email),
         %{role: role} <- TenancyAuth.membership(id, ws.id, :user) do
      role
    else
      _ -> nil
    end
  end

  defp revoked?(id), do: not is_nil(Repo.get!(ApiToken, id).revoked_at)
  defp token_count, do: Repo.aggregate(ApiToken, :count)

  # Every write: {name, token kind, surface, ok status, prepare}. `prepare`
  # builds the state the write needs and answers {method, path, body, done?},
  # where done? tells whether the write took effect.
  @cases [
    "seat a member",
    "change a member's role",
    "remove a member",
    "withdraw an invitation",
    "revoke a token",
    "rotate a token",
    "mint an admin token",
    "set a scoped secret",
    "delete a scoped secret",
    "set a flat secret",
    "delete a flat secret"
  ]

  defp write(ctx, "seat a member") do
    e = email()

    {:ws, "members_write", 201,
     {:post, ctx.base <> "/v1/members", %{email: e, role: "admin"},
      fn -> role_of(ctx.ws, e) == "admin" end}}
  end

  defp write(ctx, "change a member's role") do
    e = seated!(ctx.ws, email())

    {:ws, "members_write", 200,
     {:patch, ctx.base <> "/v1/members/" <> e, %{role: "admin"},
      fn -> role_of(ctx.ws, e) == "admin" end}}
  end

  defp write(ctx, "remove a member") do
    e = seated!(ctx.ws, email())

    {:ws, "members_write", 200,
     {:delete, ctx.base <> "/v1/members/" <> e, %{}, fn -> is_nil(role_of(ctx.ws, e)) end}}
  end

  defp write(ctx, "withdraw an invitation") do
    e = email()
    AccountsFixtures.register_user(e)
    actor = Repo.get!(ApiToken, ctx.unbound.id)
    {:ok, {:invited, inv}} = Members.add_user_member(ctx.ws.id, e, "member", actor: actor)

    {:ws, "members_write", 200,
     {:delete, ctx.base <> "/v1/invitations/" <> inv.id, %{},
      fn -> Members.list_invitations(ctx.ws.id) == [] end}}
  end

  defp write(ctx, "revoke a token") do
    victim = token!(ctx.ws.id, [], ["read"])

    {:ws, "tokens_write", 200,
     {:delete, ctx.base <> "/v1/tokens/" <> victim.id, %{}, fn -> revoked?(victim.id) end}}
  end

  defp write(ctx, "rotate a token") do
    # Bound to the same dataset, so a bound caller is within the rotate ceiling.
    victim = token!(ctx.ws.id, [dataset_bound: true], ["read"])
    before = token_count()

    {:ws, "tokens_write", 201,
     {:post, ctx.base <> "/v1/tokens/" <> victim.id <> "/rotate", %{},
      fn -> token_count() == before + 1 end}}
  end

  defp write(ctx, "mint an admin token") do
    before = token_count()

    {:ws, "tokens_write", 201,
     {:post, ctx.base <> "/v1/tokens/elevated", %{label: "minted", permissions: ["read"]},
      fn -> token_count() == before + 1 end}}
  end

  defp write(ctx, "set a scoped secret") do
    {:ws, "secrets_write", 200,
     {:put, ctx.base <> "/v1/secrets/BW_SET", %{value: "scoped-value"},
      fn -> Secrets.get("BW_SET", ctx.ws.id) == "scoped-value" end}}
  end

  defp write(ctx, "delete a scoped secret") do
    {:ok, _} = Secrets.put("BW_DEL", "scoped-value", scope: ctx.ws.id)

    {:ws, "secrets_write", 200,
     {:delete, ctx.base <> "/v1/secrets/BW_DEL", %{},
      fn -> is_nil(Secrets.get("BW_DEL", ctx.ws.id)) end}}
  end

  defp write(_ctx, "set a flat secret") do
    {:flat, "secrets_write", 200,
     {:put, "/v1/secrets/BW_SET_GLOBAL", %{value: "global-value"},
      fn -> Secrets.get("BW_SET_GLOBAL") == "global-value" end}}
  end

  defp write(_ctx, "delete a flat secret") do
    {:ok, _} = Secrets.put("BW_DEL_GLOBAL", "global-value", scope: :global)

    {:flat, "secrets_write", 200,
     {:delete, "/v1/secrets/BW_DEL_GLOBAL", %{}, fn -> is_nil(Secrets.get("BW_DEL_GLOBAL")) end}}
  end

  defp raw_for(ctx, :ws, :bound), do: ctx.bound
  defp raw_for(ctx, :flat, :bound), do: ctx.flat_bound
  defp raw_for(ctx, :ws, :unbound), do: ctx.unbound
  defp raw_for(ctx, :flat, :unbound), do: ctx.flat_unbound

  defp records, do: Repo.all(from(e in Event, where: e.action == @action, order_by: e.id))

  describe "observe (the default)" do
    for name <- @cases do
      test "#{name}: a bound admin token's write goes through and writes one audit row", ctx do
        assert DatasetBoundAdminReads.mode() == :observe
        {kind, surface, ok, {method, path, body, done?}} = write(ctx, unquote(name))
        token = raw_for(ctx, kind, :bound)

        log =
          capture_log(fn ->
            conn = send_as(token.raw, method, path, body)
            assert conn.status == ok, "#{path} answered #{conn.status}: #{conn.resp_body}"
          end)

        assert done?.()
        assert [row] = records()
        assert row.category == "access"
        assert row.actor_type == "api_token"
        assert row.actor_id == token.id
        assert row.subject == token.id
        assert row.workspace_id == if(kind == :ws, do: ctx.ws.id)
        assert row.metadata["surface"] == surface

        assert row.metadata["route"] =~
                 ~r/^#{method |> to_string() |> String.upcase()} BarkparkWeb\./

        assert log =~ "dataset_bound_admin_write token_id=#{token.id} surface=#{surface}"

        for text <- [inspect(Map.from_struct(row)), log] do
          refute text =~ token.raw
          refute text =~ @label
        end
      end
    end
  end

  describe "enforce" do
    setup do
      enforce!()
      :ok
    end

    for name <- @cases do
      test "#{name}: a bound admin token gets 403 dataset_not_bound and nothing changes", ctx do
        assert DatasetBoundAdminReads.mode() == :enforce
        {kind, _surface, _ok, {method, path, body, done?}} = write(ctx, unquote(name))

        conn = send_as(raw_for(ctx, kind, :bound).raw, method, path, body)
        assert conn.status == 403, "#{path} answered #{conn.status}: #{conn.resp_body}"
        error = Jason.decode!(conn.resp_body)["error"]
        assert error["code"] == "forbidden"
        assert error["reason"] == "dataset_not_bound"
        refute done?.()
        assert records() == []
      end
    end
  end

  test "enforce: the other token and seat writes refuse a bound admin token too", ctx do
    enforce!()
    victim = token!(ctx.ws.id, [], ["read"])
    b = ctx.base

    for {kind, method, path, body} <- [
          {:ws, :post, b <> "/v1/tokens", %{label: "read", permissions: ["read"]}},
          {:ws, :post, b <> "/v1/chat/tokens", %{label: "chat"}},
          {:ws, :post, "/v1/auth/studio-tokens", %{workspace: ctx.ws.slug}},
          {:ws, :post, "/v1/auth/app-tokens", %{email: email()}},
          {:ws, :delete, "/v1/auth/app-tokens", %{email: email()}},
          {:ws, :delete, "/v1/auth/app-tokens/" <> victim.id, %{}},
          {:ws, :delete, "/v1/shares/tokens/" <> victim.id, %{}},
          {:ws, :post, "/v1/fleet/support-tokens", %{name: "box"}},
          {:ws, :delete, "/v1/fleet/support-tokens/" <> victim.id, %{}},
          {:ws, :post, "/v1/auth/login-tickets", %{email: email()}},
          {:ws, :post, "/v1/auth/cloud-users/deprovision", %{email: email()}},
          {:flat, :post, "/v1/admin/tokens/" <> victim.id <> "/seats/restore", %{}}
        ] do
      conn = send_as(raw_for(ctx, kind, :bound).raw, method, path, body)
      assert conn.status == 403, "#{method} #{path} answered #{conn.status}: #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["error"]["reason"] == "dataset_not_bound", path
    end

    refute revoked?(victim.id)
    assert records() == []
  end

  test "observe: a login ticket without an email is not a seat write, so it is not recorded",
       ctx do
    conn = send_as(ctx.bound.raw, :post, "/v1/auth/login-tickets", %{})
    assert conn.status == 201, conn.resp_body
    assert records() == []
  end

  for mode <- [:observe, :enforce] do
    test "#{mode}: a bound admin token may revoke itself, unrecorded", ctx do
      Application.put_env(:barkpark, :dataset_bound_admin_reads, unquote(mode))

      conn = send_as(ctx.bound.raw, :delete, ctx.base <> "/v1/tokens/" <> ctx.bound.id, %{})
      assert conn.status == 200, conn.resp_body
      assert revoked?(ctx.bound.id)
      assert records() == []
    end

    test "#{mode}: an unbound admin token on the same seat writes all of them, unrecorded",
         ctx do
      Application.put_env(:barkpark, :dataset_bound_admin_reads, unquote(mode))

      for name <- @cases do
        {kind, _surface, ok, {method, path, body, done?}} = write(ctx, name)
        conn = send_as(raw_for(ctx, kind, :unbound).raw, method, path, body)
        assert conn.status == ok, "#{name}: #{path} answered #{conn.status}: #{conn.resp_body}"
        assert done?.(), name
      end

      assert records() == []
    end
  end
end
