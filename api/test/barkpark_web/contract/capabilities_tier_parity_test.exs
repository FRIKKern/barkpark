defmodule BarkparkWeb.Contract.CapabilitiesTierParityTest do
  @moduledoc """
  MANIFEST TIER == PIPELINE TIER.

  `GET /v1/capabilities` is the contract every `bp` / MCP / SDK client reads to
  decide which verbs it MAY call, so its `auth_tier` is an authorization
  statement made TO a client. It is only safe while it equals the judgment the
  REQUEST PIPELINES make about the same credential. Until this file existed that
  equality rested on two hand-written ladders agreeing by review:
  `Barkpark.Plugins.Capabilities.tier_for_token/1` carried its own `cond` over
  `permits?/2`, and the plugs carried theirs. (That second copy is also the
  `capabilities > auth` sideways edge the cqv8 boundary gate reports —
  task-0cdfc8ce6e8d17c3.)

  This file pins the equality from BOTH ends and never re-reads the manifest
  ladder to compute the expected side. `pipeline_tier/1` derives the ENFORCED
  tier by driving REAL `%Plug.Conn{}`s through the REAL plugs the router mounts:

      "admin"  BarkparkWeb.Plugs.RequireAdmin              (pipeline :require_admin)
      "write"  BarkparkWeb.Plugs.RequireWritePermission    (pipeline :require_write)
      "read"   BarkparkWeb.Plugs.ResolveWorkspace          (the scoped read gate,
               i.e. `TenancyAuth.authorize(token, ws, :read)` = membership AND
               `permits?(token, :read)`)
      "+chat"  BarkparkWeb.Plugs.RequireChatAccess         (pipeline :require_chat_access)
               resolving `conn.assigns.chat_scope` to `{:workspace, _}`
      "none"   BarkparkWeb.Plugs.RequireToken refuses the credential outright

  and `pipeline :require_token`'s own read-tier clamp (RequireToken → PublicRead
  → RequireWriteForMutation) is pinned separately below, since that is the stack
  that decides what a `read` token may NOT do.

  A rung that drifts on EITHER side reds here: change the manifest ladder and the
  advertised side moves; change a plug's predicate and the enforced side moves.

  ## Red-without / green-with

  Mutating one rung of `Barkpark.Tenancy.Auth.tier_of/1` (dropping the `:write`
  clause, so a write token reports "read") reds
  `for every token kind` on the write row and nothing else. Restoring is green.
  The runs are pasted in the PR body.

  ## Non-vacuity

  `the token kinds really do span distinct rungs` guards the loop from passing
  because every fixture landed on the same tier — e.g. all "none" because a
  fixture failed to mint.
  """

  # async: false — mints api_tokens + a workspace and drives plugs that write a
  # `last_used_at` touch; kept out of the async pool with the sibling
  # token-minting contract tests.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Plugins.Capabilities
  alias BarkparkWeb.Plugs.PublicRead
  alias BarkparkWeb.Plugs.RequireAdmin
  alias BarkparkWeb.Plugs.RequireChatAccess
  alias BarkparkWeb.Plugs.RequireToken
  alias BarkparkWeb.Plugs.RequireWriteForMutation
  alias BarkparkWeb.Plugs.RequireWritePermission
  alias BarkparkWeb.Plugs.ResolveWorkspace

  @kinds [
    {:read, ["read"]},
    {:write, ["write"]},
    {:admin, ["admin"]},
    {:chat, ["chat"]},
    {:read_chat, ["read", "chat"]}
  ]

  setup do
    ws = Barkpark.TenancyFixtures.create_workspace!()
    n = System.unique_integer([:positive])

    tokens =
      for {kind, perms} <- @kinds, into: %{} do
        raw = "tier-parity-#{kind}-#{n}"

        {:ok, token} =
          Barkpark.Auth.create_token(raw, "tier-parity-#{kind}", "test", perms, ws.id)

        {kind, {raw, token}}
      end

    {:ok, ws: ws, tokens: tokens}
  end

  # ── the PIPELINE side — real conns, real plugs, never the manifest ladder ──

  defp bearer(raw, ws, method, path) do
    conn =
      Phoenix.ConnTest.build_conn(method, path)
      |> Map.put(:path_params, %{"workspace_slug" => ws.slug})

    if raw, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{raw}"), else: conn
  end

  # RequireToken is the door every one of these pipelines opens with. `:denied`
  # is the tier-"none" floor: the credential never resolved.
  defp resolved(raw, ws, method \\ :get, path \\ "/v1/schemas") do
    conn = RequireToken.call(bearer(raw, ws, method, path), [])
    if conn.halted, do: :denied, else: {:ok, conn}
  end

  defp gate(raw, ws, fun) do
    case resolved(raw, ws) do
      {:ok, conn} -> not fun.(conn).halted
      :denied -> false
    end
  end

  # `pipeline :require_admin` — RequireToken then RequireAdmin.
  defp admin_gate_admits?(raw, ws), do: gate(raw, ws, &RequireAdmin.call(&1, []))

  # `pipeline :require_write` — RequireWritePermission on the resolved token.
  defp write_gate_admits?(raw, ws), do: gate(raw, ws, &RequireWritePermission.call(&1, []))

  # THE READ GATE. ResolveWorkspace is the plug every scoped read pipeline
  # mounts, and its membership arm is `TenancyAuth.authorize(token, ws, :read)`
  # — membership AND `permits?(token, :read)`. A token the manifest calls
  # "read" must get through it; one it calls "none" must not.
  defp read_gate_admits?(raw, ws), do: gate(raw, ws, &ResolveWorkspace.call(&1, []))

  # `pipeline :require_chat_access` — the ORTHOGONAL grant. `{:workspace, _}` is
  # the scope RequireChatAccess gives a NON-admin, workspace-bound chat token,
  # and it is exactly what the `+chat` suffix mirrors.
  defp chat_gate_workspace_scoped?(raw, ws) do
    case resolved(raw, ws) do
      {:ok, conn} ->
        conn = RequireChatAccess.call(conn, [])
        not conn.halted and match?({:workspace, _}, conn.assigns[:chat_scope])

      :denied ->
        false
    end
  end

  defp pipeline_tier(raw, ws) do
    base =
      cond do
        admin_gate_admits?(raw, ws) -> "admin"
        write_gate_admits?(raw, ws) -> "write"
        read_gate_admits?(raw, ws) -> "read"
        true -> "none"
      end

    if base != "admin" and chat_gate_workspace_scoped?(raw, ws),
      do: base <> "+chat",
      else: base
  end

  # `pipeline :require_token` — the read-tier CLAMP stack, on the given method.
  defp require_token_stack_admits?(raw, ws, method, path) do
    case resolved(raw, ws, method, path) do
      {:ok, conn} ->
        conn = conn |> PublicRead.call([]) |> RequireWriteForMutation.call([])
        not conn.halted

      :denied ->
        false
    end
  end

  # ── the MANIFEST side ────────────────────────────────────────────────────

  # Through the live HTTP surface, so this reads the tier a real client is told.
  defp manifest_tier(conn, raw) do
    conn
    |> then(fn c ->
      if raw, do: put_req_header(c, "authorization", "Bearer #{raw}"), else: c
    end)
    |> get("/v1/capabilities")
    |> json_response(200)
    |> Map.fetch!("auth_tier")
  end

  # ── the pins ─────────────────────────────────────────────────────────────

  describe "manifest tier == pipeline tier" do
    test "for every token kind", %{conn: conn, ws: ws, tokens: tokens} do
      for {kind, {raw, token}} <- tokens do
        enforced = pipeline_tier(raw, ws)
        advertised = Capabilities.tier_for_token(token)

        assert advertised == enforced,
               "#{kind}: the manifest ADVERTISES tier #{inspect(advertised)} but the request " <>
                 "pipelines ENFORCE #{inspect(enforced)} for the same token — the two ladders " <>
                 "have drifted. One owner: Barkpark.Tenancy.Auth.tier_of/1."

        # And the same equality on the wire. `project/2` echoes the BASE rank —
        # the `+chat` suffix is a capability, not a rank — so compare bases.
        assert manifest_tier(conn, raw) == Capabilities.base_tier(enforced),
               "#{kind}: GET /v1/capabilities echoed a different base tier than the pipelines enforce"
      end
    end

    test "an anonymous caller is `none` on both sides", %{conn: conn, ws: ws} do
      assert pipeline_tier(nil, ws) == "none"
      assert Capabilities.tier_for_token(nil) == "none"
      assert manifest_tier(conn, nil) == "none"
    end
  end

  describe "the rungs really discriminate (non-vacuity)" do
    test "the token kinds really do span distinct rungs", %{ws: ws, tokens: tokens} do
      spread = Map.new(tokens, fn {kind, {raw, _}} -> {kind, pipeline_tier(raw, ws)} end)

      assert spread == %{
               read: "read",
               write: "write",
               admin: "admin",
               chat: "none+chat",
               read_chat: "read+chat"
             },
             "the pipeline side must land the fixtures on DIFFERENT rungs, else the parity loop " <>
               "above can pass without discriminating anything; got: #{inspect(spread)}"
    end

    test "the read-tier clamp is what a `read` token may not do", %{ws: ws, tokens: tokens} do
      {read_raw, _} = tokens[:read]
      {write_raw, _} = tokens[:write]

      # Both are admitted a GET through `pipeline :require_token` …
      assert require_token_stack_admits?(read_raw, ws, :get, "/v1/schemas")
      assert require_token_stack_admits?(write_raw, ws, :get, "/v1/schemas")

      # … and RequireWriteForMutation is the thing that refuses the read token a
      # MUTATION on that same pipeline.
      refute require_token_stack_admits?(read_raw, ws, :post, "/v1/access"),
             "RequireWriteForMutation must refuse a read-tier token every mutation on :require_token"

      assert require_token_stack_admits?(write_raw, ws, :post, "/v1/access"),
             "a write token must pass the read-tier clamp"
    end

    test "`chat` is orthogonal on BOTH sides — it lifts no rank", %{ws: ws, tokens: tokens} do
      {chat_raw, chat_token} = tokens[:chat]
      {read_chat_raw, read_chat_token} = tokens[:read_chat]

      assert pipeline_tier(chat_raw, ws) == "none+chat"
      assert Capabilities.tier_for_token(chat_token) == "none+chat"

      assert pipeline_tier(read_chat_raw, ws) == "read+chat"
      assert Capabilities.tier_for_token(read_chat_token) == "read+chat"

      # The suffix rides ALONGSIDE the rank: strip it and the rank is what the
      # non-chat ladder would have produced on its own.
      assert Capabilities.base_tier(pipeline_tier(chat_raw, ws)) == "none"
      assert Capabilities.base_tier(pipeline_tier(read_chat_raw, ws)) == "read"
    end
  end

  describe "one owner" do
    test "the manifest does not carry its own copy of the ladder" do
      src = File.read!("lib/barkpark/plugins/capabilities.ex")

      refute src =~ "Barkpark.Auth.has_permission?(token",
             "capabilities.ex must not re-derive an authorization decision from the auth " <>
               "context — that IS the capabilities>auth boundary edge. Consume " <>
               "Barkpark.Tenancy.Auth.tier_of/1 instead."

      assert src =~ "defdelegate tier_for_token(token), to: Barkpark.Tenancy.Auth, as: :tier_of",
             "tier_for_token/1 must stay a one-line delegation to the single owner"
    end
  end
end
