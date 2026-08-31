defmodule BarkparkWeb.TicketKeysWorkspaceAttributionTest do
  @moduledoc """
  task-ee099124abc578ef — `/v1/plugins/tickets/keys` must attribute every key
  operation to the CALLER'S OWN workspace, never to the seeded Default.

  ## What this file pins, and why it is not RED-before

  The row that commissioned this file asserted a live cross-tenant defect: that
  the plugin `:api` bucket (`[:api, :require_admin]`, router.ex `scope
  "/v1/plugins"`) runs `AssignDefaultScope` with NO `DeriveWorkspaceFromToken`,
  so `TicketKeysController.current_workspace_id/1` — which reads exactly
  `conn.assigns[:current_workspace]` — resolved to the seeded Default workspace
  for EVERY admin, collapsing all six actions into one shared key pool.

  That premise was true when the `:flat_admin_api` pipeline was introduced, and
  it is the premise its header comment still described. It stopped being true on
  2026-08-24: `8dd6600f99` (#13886) moved `DeriveWorkspaceFromToken` INTO the
  `:api` pipeline itself, ahead of `AssignDefaultScope` (router.ex `pipeline
  :api`). Because the plug is no-op-if-set and now runs FIRST, a workspace-bound
  bearer lands on its own workspace on `[:api, :require_admin]` too — the
  tickets keys surface inherited the fix without anyone editing it.

  So this file is GREEN on the tree that commissioned it. It is committed
  anyway, because the surface had NO request-level attribution coverage at all:
  the whole guarantee rested on one plug's position inside a pipeline this
  controller never names, three indirections away (plugin route table → plugin
  `:api` bucket → `:api` pipeline ordering). `flat_alias_tenancy_test.exs` pins
  that ordering for `/v1/data`; nothing pinned that TICKET KEYS — a live
  credential-minting surface — actually rides it. Reordering those two plugs, or
  moving the plugin bucket to a pipeline without the derivation, reopens a
  cross-tenant credential defect that no existing test would catch.

  ## Non-vacuity

  Both tenants are seeded with a real key, and every cross-tenant refusal is
  paired with a positive control proving the SAME request shape succeeds against
  the caller's own key — so a 404 is green because the fence refused, not
  because the handler is inert, the fixture empty, or the route missing.
  Assertions are on the `workspace_id` actually written to the row store, never
  on status alone: these actions answered 200 while talking to the wrong tenant.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @path "/v1/plugins/tickets/keys"

  setup do
    # The Default workspace must EXIST for the defect to be expressible at all —
    # `AssignDefaultScope` is a no-op on a tenancy that was never seeded, which
    # is precisely the configuration in which this class of bug is invisible.
    {default_ws, _default_project} = TenancyFixtures.ensure_default_scope!()

    ws_a = TenancyFixtures.create_workspace!()
    ws_b = TenancyFixtures.create_workspace!()

    raw_a = unique("tk-attr-admin-a")
    raw_b = unique("tk-attr-admin-b")

    {:ok, _} = admin_token(raw_a, "ticket-keys admin A", ws_a.id)
    {:ok, _} = admin_token(raw_b, "ticket-keys admin B", ws_b.id)

    # One pre-existing key per tenant, minted BELOW the HTTP surface, so the
    # listing assertions cannot pass on an empty pool and the by-id fences have
    # a real foreign row to refuse.
    {:ok, %{key: key_a}} = Keys.mint(%{name: "WS-A-OWN-KEY", workspace_id: ws_a.id})
    {:ok, %{key: key_b}} = Keys.mint(%{name: "WS-B-OWN-KEY", workspace_id: ws_b.id})

    {:ok, %{key: default_key}} =
      Keys.mint(%{name: "DEFAULT-TENANT-KEY", workspace_id: default_ws.id})

    %{
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      raw_a: raw_a,
      raw_b: raw_b,
      key_a: key_a,
      key_b: key_b,
      default_key: default_key
    }
  end

  describe "mint (POST) attributes to the caller's own workspace" do
    test "a ws-A admin's key is bound to ws-A, not the seeded Default", ctx do
      body =
        ctx.raw_a
        |> authed()
        |> post(@path, Jason.encode!(%{name: "MINTED-BY-WS-A"}))
        |> json_response(201)

      minted = Repo.get(ApiToken, body["key"]["id"])

      refute is_nil(minted), "the mint should have created a ticket key row"

      assert minted.workspace_id == ctx.ws_a.id,
             "a ws-A admin minted a live ticket credential into workspace " <>
               "#{inspect(minted.workspace_id)} instead of their own #{inspect(ctx.ws_a.id)}"

      refute minted.workspace_id == ctx.default_ws.id,
             "the mint collapsed to the seeded Default workspace"

      # The store agrees with the wire, in both directions.
      assert "MINTED-BY-WS-A" in key_names(Keys.list(ctx.ws_a))
      refute "MINTED-BY-WS-A" in key_names(Keys.list(ctx.default_ws))
    end
  end

  describe "index (GET) lists only the caller's own workspace" do
    test "a ws-A admin sees A's keys and neither B's nor Default's", ctx do
      names = ctx.raw_a |> authed() |> get(@path) |> json_response(200) |> response_key_names()

      assert "WS-A-OWN-KEY" in names,
             "the ws-A admin cannot see their own workspace's ticket key"

      refute "WS-B-OWN-KEY" in names, "the ticket-key index leaked workspace B's keys to ws-A"

      refute "DEFAULT-TENANT-KEY" in names,
             "the ticket-key index leaked the Default workspace's keys to ws-A"
    end

    test "and the mirror: a ws-B admin sees only B's", ctx do
      names = ctx.raw_b |> authed() |> get(@path) |> json_response(200) |> response_key_names()

      assert "WS-B-OWN-KEY" in names
      refute "WS-A-OWN-KEY" in names, "the ticket-key index leaked workspace A's keys to ws-B"
      refute "DEFAULT-TENANT-KEY" in names
    end
  end

  describe "the by-id actions cannot reach another tenant's key" do
    # Each refusal is PAIRED with the same call against the caller's own key.
    # Without the positive control a 404 proves nothing — a broken route, a
    # dead handler and a correct fence are indistinguishable.

    test "rotate", ctx do
      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_a.id}/rotate", "") |> status() ==
               404,
             "a ws-B admin rotated workspace A's ticket key"

      # The rotate did not merely 404 — A's secret is untouched.
      assert Repo.get!(ApiToken, ctx.key_a.id).token_hash == ctx.key_a.token_hash

      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_b.id}/rotate", "") |> status() ==
               200,
             "positive control: the same admin must be able to rotate their OWN key"
    end

    test "pause", ctx do
      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_a.id}/pause", "") |> status() ==
               404,
             "a ws-B admin paused workspace A's ticket key"

      assert is_nil(Repo.get!(ApiToken, ctx.key_a.id).paused_at),
             "workspace A's key was paused by a ws-B admin"

      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_b.id}/pause", "") |> status() ==
               200,
             "positive control: the same admin must be able to pause their OWN key"
    end

    test "unpause", ctx do
      {:ok, _} = Keys.pause(ctx.key_a.id, ctx.ws_a.id)
      {:ok, _} = Keys.pause(ctx.key_b.id, ctx.ws_b.id)

      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_a.id}/unpause", "") |> status() ==
               404,
             "a ws-B admin unpaused workspace A's ticket key"

      refute is_nil(Repo.get!(ApiToken, ctx.key_a.id).paused_at),
             "workspace A's key was un-muted by a ws-B admin"

      assert ctx.raw_b |> authed() |> post("#{@path}/#{ctx.key_b.id}/unpause", "") |> status() ==
               200,
             "positive control: the same admin must be able to unpause their OWN key"
    end

    test "delete (revoke)", ctx do
      assert ctx.raw_b |> authed() |> delete("#{@path}/#{ctx.key_a.id}") |> status() == 404,
             "a ws-B admin revoked workspace A's ticket key"

      assert is_nil(Repo.get!(ApiToken, ctx.key_a.id).revoked_at),
             "workspace A's key was revoked by a ws-B admin"

      assert ctx.raw_b |> authed() |> delete("#{@path}/#{ctx.key_b.id}") |> status() == 200,
             "positive control: the same admin must be able to revoke their OWN key"
    end
  end

  describe "the instance-wide operator" do
    # DELIBERATE, and pinned here WITH its reason so it cannot silently rot into
    # the defect above. `DeriveWorkspaceFromToken` is fail-soft: a token whose
    # `workspace_id` is nil names no tenant of its own, so `AssignDefaultScope`
    # still binds it to Default. That is the legitimate host-operator path and
    # the plug's own moduledoc carves it out by name ("no regression on the
    # nil-token path"). It is NOT the census defect: the collapse only ever
    # applies to a principal that never claimed a workspace, never to one whose
    # token is bound elsewhere.
    #
    # The row is inserted directly because `Auth.create_token/5` back-fills a
    # nil `workspace_id` to the seeded Default (see its @doc), so it cannot
    # produce this shape while a Default exists. This IS the shape it produces
    # on a tenancy that was never seeded, and the shape every pre-tenancy token
    # carried before the backfill — i.e. what still reaches this pipeline in the
    # wild.
    test "an un-bound (nil-workspace) admin token still lands in Default", ctx do
      raw = unique("tk-attr-instance-admin")

      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "instance-wide operator",
          dataset: "production",
          permissions: ["read", "write", "admin"],
          workspace_id: nil
        })
        |> Repo.insert()

      assert is_nil(token.workspace_id)

      body =
        raw
        |> authed()
        |> post(@path, Jason.encode!(%{name: "MINTED-BY-INSTANCE-ADMIN"}))
        |> json_response(201)

      assert Repo.get!(ApiToken, body["key"]["id"]).workspace_id == ctx.default_ws.id

      names = raw |> authed() |> get(@path) |> json_response(200) |> response_key_names()

      assert "DEFAULT-TENANT-KEY" in names
      refute "WS-A-OWN-KEY" in names, "the instance-wide operator's listing widened past Default"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp admin_token(raw, label, workspace_id),
    do: Auth.create_token(raw, label, "production", ["read", "write", "admin"], workspace_id)

  defp authed(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp status(%Plug.Conn{status: status}), do: status

  defp response_key_names(%{"keys" => keys}), do: Enum.map(keys, & &1["name"])

  defp key_names(keys), do: Enum.map(keys, & &1.name)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
