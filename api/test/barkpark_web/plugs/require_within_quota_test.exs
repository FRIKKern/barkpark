defmodule BarkparkWeb.Plugs.RequireWithinQuotaTest do
  @moduledoc """
  Per-workspace quota gate at the mutate seam (perfect-plan-build W1, D11-D14).

  Proves the gate the two scoped mutate pipelines mount BEFORE
  RequireWritePermission: a suspended or over-quota workspace is halted with a
  JSON error envelope, an under-quota / unlimited one passes, and an allowed
  MEDIA write emits the one per-workspace telemetry event the media path has no
  span for. Also pins the content-span workspace_id tag (D12) and the
  `Barkpark.Tenancy.Quota` context (suspend flips the flag + writes the
  audit-chain line).

  async: false — telemetry handlers and Logger metadata are global process state.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.{Quota, Workspace}
  alias BarkparkWeb.Plugs.{DeriveWorkspaceFromToken, RequireWithinQuota}

  import Ecto.Query, only: [from: 2]

  defp call(conn, ws, opts \\ []) do
    conn
    |> assign(:current_workspace, ws)
    |> RequireWithinQuota.call(RequireWithinQuota.init(opts))
  end

  defp body(conn), do: Phoenix.json_library().decode!(conn.resp_body)

  describe "enforcement — the halt-with-JSON-envelope gate" do
    test "a SUSPENDED workspace is blocked 403 workspace_suspended with the reason", %{conn: conn} do
      ws = %Workspace{
        id: Ecto.UUID.generate(),
        suspended: true,
        suspended_reason: "billing lapsed"
      }

      conn = call(conn, ws)

      assert conn.halted
      assert conn.status == 403
      assert %{"error" => %{"code" => "workspace_suspended"} = err} = body(conn)
      assert err["details"]["reason"] == "billing lapsed"
    end

    test "an OVER-QUOTA workspace is blocked 402 quota_exceeded and an audit line is written",
         %{conn: conn} do
      # quota: 0 → usage (0 docs) is not < 0 → over quota, deterministically.
      ws = %Workspace{id: Ecto.UUID.generate(), quota: 0, suspended: false}

      conn = call(conn, ws)

      assert conn.halted
      assert conn.status == 402
      assert %{"error" => %{"code" => "quota_exceeded"} = err} = body(conn)
      assert err["details"]["quota"] == 0

      # The wall being hit is observable on the tamper-evident audit chain.
      assert Repo.exists?(
               from(e in Event,
                 where: e.action == "workspace.quota_exceeded" and e.workspace_id == ^ws.id
               )
             )
    end

    test "an UNDER-QUOTA workspace passes (usage < cap)", %{conn: conn} do
      ws = %Workspace{id: Ecto.UUID.generate(), quota: 5, suspended: false}

      conn = call(conn, ws)

      refute conn.halted
      assert conn.status == nil
    end

    test "an UNLIMITED workspace (quota nil) passes without touching the DB", %{conn: conn} do
      ws = %Workspace{id: Ecto.UUID.generate(), quota: nil, suspended: false}

      conn = call(conn, ws)

      refute conn.halted
    end

    test "no resolved workspace fails OPEN — the plug never crashes on a nil assign", %{
      conn: conn
    } do
      # No :current_workspace assign at all (share_public / anonymous path).
      conn = RequireWithinQuota.call(conn, RequireWithinQuota.init([]))

      refute conn.halted
    end
  end

  describe "metering — the media-seam telemetry (D12)" do
    setup do
      handler = "test-media-meter-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :media, :mutate],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:media_mutate, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "an allowed MEDIA write emits [:barkpark, :media, :mutate] tagged by workspace_id",
         %{conn: conn} do
      ws = %Workspace{id: Ecto.UUID.generate(), quota: nil, suspended: false}

      conn = call(conn, ws, meter: :media)

      refute conn.halted

      assert_receive {:media_mutate, [:barkpark, :media, :mutate], %{count: 1},
                      %{workspace_id: id}}

      assert id == ws.id
    end

    test "the DOC pipeline (no :media meter) emits NO media event — the content span covers it",
         %{conn: conn} do
      ws = %Workspace{id: Ecto.UUID.generate(), quota: nil, suspended: false}

      conn = call(conn, ws)

      refute conn.halted
      refute_receive {:media_mutate, _, _, _}, 100
    end

    test "a BLOCKED write emits no media meter (no write happened)", %{conn: conn} do
      ws = %Workspace{id: Ecto.UUID.generate(), suspended: true, suspended_reason: "x"}

      call(conn, ws, meter: :media)

      refute_receive {:media_mutate, _, _, _}, 100
    end
  end

  describe "content spans carry workspace_id (D12)" do
    setup do
      handler = "test-content-mutate-ws-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :content, :mutate, :stop],
        fn _event, _measurements, metadata, _cfg ->
          send(test_pid, {:mutate_stop, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "apply_mutations tags the mutate span with the scoped workspace_id" do
      ws_id = Ecto.UUID.generate()

      {:ok, _} = Barkpark.Content.apply_mutations([], "production", workspace_id: ws_id)

      assert_receive {:mutate_stop, %{workspace_id: ^ws_id}}
    end

    test "an unscoped apply_mutations tags the span 'global', never a nil that crashes the reporter" do
      {:ok, _} = Barkpark.Content.apply_mutations([], "production", [])

      assert_receive {:mutate_stop, %{workspace_id: "global"}}
    end
  end

  describe "Barkpark.Tenancy.Quota context" do
    test "within_quota?/1 — suspended is never within quota; nil quota is unlimited" do
      refute Quota.within_quota?(%Workspace{id: Ecto.UUID.generate(), suspended: true})
      assert Quota.within_quota?(%Workspace{id: Ecto.UUID.generate(), quota: nil})
      refute Quota.within_quota?(%Workspace{id: Ecto.UUID.generate(), quota: 0})
    end

    test "suspend/2 flips the flag, stamps the reason, and writes a workspace.suspended audit line" do
      ws = create_workspace!()

      assert {:ok, updated} = Quota.suspend(ws, "manual operator suspend")
      assert updated.suspended
      assert updated.suspended_reason == "manual operator suspend"
      assert updated.suspended_at

      assert Repo.exists?(
               from(e in Event,
                 where: e.action == "workspace.suspended" and e.workspace_id == ^ws.id
               )
             )

      # Round-trips through the DB — the flag is persisted, not just in-struct.
      reloaded = Repo.get!(Workspace, ws.id)
      assert reloaded.suspended
    end

    test "reinstate/1 clears the suspension" do
      ws = create_workspace!()
      {:ok, suspended} = Quota.suspend(ws, "temp")
      assert suspended.suspended

      {:ok, back} = Quota.reinstate(suspended)
      refute back.suspended
      refute back.suspended_reason
    end

    test "set_quota/2 writes a cap that check/1 enforces, and nil restores unlimited" do
      ws = create_workspace!()
      proj = create_project!(ws)

      # A fresh workspace is uncapped (NULL) → within quota regardless of count.
      assert ws.quota == nil
      assert Quota.within_quota?(ws)

      # Set a cap of 1, then create 2 documents scoped to the workspace so usage
      # (2) exceeds the cap (1) — check/1 blocks at N+1 documents.
      {:ok, capped} = Quota.set_quota(ws, 1)
      assert capped.quota == 1

      {:ok, _} = create_document_in!(ws, proj)
      {:ok, _} = create_document_in!(ws, proj)

      # Round-trips through the DB — the cap is persisted, not just in-struct.
      reloaded = Repo.get!(Workspace, ws.id)
      assert reloaded.quota == 1
      assert Quota.check(reloaded) == {:error, :quota_exceeded}

      # nil clears the cap back to unlimited (NULL) → within quota, unbounded.
      {:ok, cleared} = Quota.set_quota(reloaded, nil)
      assert cleared.quota == nil
      assert Repo.get!(Workspace, ws.id).quota == nil
      assert Quota.within_quota?(cleared)
      assert Quota.check(cleared) == :ok
    end
  end

  describe "DeriveWorkspaceFromToken — closing the flat :media_mutate quota hole (D14/D30)" do
    defp derive(conn), do: DeriveWorkspaceFromToken.call(conn, DeriveWorkspaceFromToken.init([]))

    test "a token carrying a workspace_id derives THAT workspace onto :current_workspace", %{
      conn: conn
    } do
      ws = create_workspace!()

      conn = conn |> assign(:api_token, %ApiToken{workspace_id: ws.id}) |> derive()

      assert conn.assigns.current_workspace.id == ws.id
      refute conn.halted
    end

    test "two tokens on the SAME 'production' dataset each derive their OWN workspace (D30 win)",
         %{conn: conn} do
      # The whole point of token-derive over dataset-string derive (D30): a
      # `production` slug is unique only per-project, so it is cross-workspace
      # ambiguous. The token's workspace_id is not — each caller lands on its own.
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      conn_a =
        conn
        |> assign(:api_token, %ApiToken{workspace_id: ws_a.id, dataset: "production"})
        |> derive()

      conn_b =
        conn
        |> assign(:api_token, %ApiToken{workspace_id: ws_b.id, dataset: "production"})
        |> derive()

      assert conn_a.assigns.current_workspace.id == ws_a.id
      assert conn_b.assigns.current_workspace.id == ws_b.id
      refute conn_a.assigns.current_workspace.id == conn_b.assigns.current_workspace.id
    end

    test "a NIL-workspace_id token leaves :current_workspace unset (today's Default-Workspace path)",
         %{conn: conn} do
      conn =
        conn
        |> assign(:api_token, %ApiToken{workspace_id: nil, dataset: "production"})
        |> derive()

      refute Map.has_key?(conn.assigns, :current_workspace)
      refute conn.halted
    end

    test "an already-resolved :current_workspace is NEVER overwritten", %{conn: conn} do
      resolved = create_workspace!()
      other = create_workspace!()

      conn =
        conn
        |> assign(:current_workspace, resolved)
        |> assign(:api_token, %ApiToken{workspace_id: other.id})
        |> derive()

      assert conn.assigns.current_workspace.id == resolved.id
    end

    test "a workspace_id pointing at no row falls through untouched (fail-soft, no 500)", %{
      conn: conn
    } do
      conn = conn |> assign(:api_token, %ApiToken{workspace_id: Ecto.UUID.generate()}) |> derive()

      refute Map.has_key?(conn.assigns, :current_workspace)
      refute conn.halted
    end

    test "no :api_token assign falls through untouched", %{conn: conn} do
      conn = derive(conn)

      refute Map.has_key?(conn.assigns, :current_workspace)
      refute conn.halted
    end
  end

  describe "flat media write meters to the token's OWN workspace (derive → quota chain)" do
    setup do
      handler = "test-flat-media-meter-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :media, :mutate],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:media_mutate, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp flat_chain(conn, ws_id) do
      conn
      |> assign(:api_token, %ApiToken{workspace_id: ws_id, dataset: "production"})
      |> DeriveWorkspaceFromToken.call(DeriveWorkspaceFromToken.init([]))
      |> RequireWithinQuota.call(RequireWithinQuota.init(meter: :media))
    end

    test "two workspaces sharing dataset 'production' each meter to their OWN workspace", %{
      conn: conn
    } do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      conn_a = flat_chain(conn, ws_a.id)
      conn_b = flat_chain(conn, ws_b.id)

      refute conn_a.halted
      refute conn_b.halted

      assert_receive {:media_mutate, [:barkpark, :media, :mutate], %{count: 1},
                      %{workspace_id: id_a}}

      assert_receive {:media_mutate, [:barkpark, :media, :mutate], %{count: 1},
                      %{workspace_id: id_b}}

      # Each flat write metered to its own workspace — NOT the singleton Default.
      assert Enum.sort([id_a, id_b]) == Enum.sort([ws_a.id, ws_b.id])
    end

    test "an OVER-QUOTA derived workspace is blocked 402 quota_exceeded on the flat path", %{
      conn: conn
    } do
      ws = create_workspace!()
      # quota 0 → usage (0) is not < 0 → deterministically over quota.
      {:ok, _} = Quota.set_quota(ws, 0)

      conn = flat_chain(conn, ws.id)

      assert conn.halted
      assert conn.status == 402
      assert %{"error" => %{"code" => "quota_exceeded"}} = body(conn)

      # A blocked write meters nothing — no telemetry event fired.
      refute_receive {:media_mutate, _, _, _}, 100
    end

    test "a NIL-token flat write is unmetered here (falls to AssignDefaultScope downstream)", %{
      conn: conn
    } do
      # No workspace derived → RequireWithinQuota sees no :current_workspace and
      # fails OPEN. In the live pipeline AssignDefaultScope then stamps the Default
      # Workspace, preserving today's behavior. No media meter fires at this seam.
      conn =
        conn
        |> assign(:api_token, %ApiToken{workspace_id: nil, dataset: "production"})
        |> DeriveWorkspaceFromToken.call(DeriveWorkspaceFromToken.init([]))
        |> RequireWithinQuota.call(RequireWithinQuota.init(meter: :media))

      refute conn.halted
      refute_receive {:media_mutate, _, _, _}, 100
    end
  end
end
