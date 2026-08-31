defmodule BarkparkWeb.TicketKeyRouteSweepTest do
  @moduledoc """
  CROWN JEWEL (Barkpark Tickets, charter Decision 1): the repo-pinned proof that
  a leaked ticket key's blast radius is nothing but the ticket surface — "leaked
  key = spam, never data."

  It enumerates EVERY route in `BarkparkWeb.Router.__routes__()`, presents a live
  `kind == "ticket"` key as a Bearer, and asserts the key is treated EXACTLY like
  an anonymous caller everywhere outside the declared `/v1/tickets` submitter
  prefix — i.e. presenting the key grants NOTHING beyond no-token-at-all. Then it
  proves the boundary has teeth (token-gated `/v1` routes actively 401/403 the
  key), that revoke/rotate kill instantly, that a paused key is a distinguishable
  403, and that the fail-closed choke point (`Auth.verify_token/1`) never returns
  a ticket-kind row.

  The `/v1/tickets` exemption is a DECLARED prefix list (`@exempt_prefixes`).
  It's empty benefit in THIS worktree — no plugin declares `/v1/tickets` routes
  yet (they land in a sibling slice) — but written so the exemption becomes
  meaningful the instant those routes merge, WITHOUT touching this test.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Plugins.Tickets.Keys

  import Barkpark.TenancyFixtures

  # The ONLY surface a ticket key legitimately reaches. Declared as a prefix
  # list so the sweep's exemption survives the sibling slice that adds the
  # actual `/v1/tickets` submitter routes.
  @exempt_prefixes ["/v1/tickets"]

  # Carved back OUT of the exemption: the OPERATOR statics live INSIDE the
  # `/v1/tickets` prefix (`/v1/tickets/inbox…`, `:token_root` per the charter
  # route table) but are emphatically NOT submitter surface — the sweep must
  # keep proving a ticket key is treated like an anonymous caller there the
  # instant the sibling slice mounts them.
  @never_exempt_prefixes ["/v1/tickets/inbox"]

  @http_verbs [:get, :post, :put, :patch, :delete, :head, :options]

  # A keyed outcome in this set, where the anonymous caller was NOT refused, is
  # a de-escalation rather than an elevation. See the `cond` in the sweep.
  @refusal_statuses [401, 403]

  setup do
    # Neutralise rate limiting for the sweep: hundreds of requests share one IP
    # bucket, and a 429 would masquerade as (or mask) an auth outcome. High
    # limits keep every response a genuine auth/routing result.
    prev = Application.get_env(:barkpark, :rate_limits, [])

    Application.put_env(:barkpark, :rate_limits,
      read_per_minute: 1_000_000,
      write_per_minute: 1_000_000
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, prev) end)

    ws = create_workspace!()
    {:ok, %{key: key, raw: raw}} = Keys.mint(%{name: "Sweep — Kari", workspace_id: ws.id})
    %{key: key, raw: raw, workspace: ws}
  end

  test "a live ticket key gets NO more access than an anonymous caller on any route",
       %{raw: raw} do
    offenders =
      for route <- sweepable_routes(),
          path = concrete_path(route.path),
          not exempt?(path) do
        anon = status_for(route.verb, path, nil)
        keyed = status_for(route.verb, path, raw)

        cond do
          anon == keyed ->
            nil

          # STRICTLY MORE REFUSING than anonymous is not an elevation — it is
          # the opposite, and this test's invariant is "NO MORE access than an
          # anonymous caller" (see @moduledoc), which a refusal satisfies.
          #
          # The flat `/v1/data` READ pipeline refuses ANY presented-but-
          # unverifiable bearer with 401 (task-46872cadcfc50c5f, closing a
          # silent tenant swap where a decayed token was served another
          # tenant's rows at 200). A ticket key is unverifiable BY DESIGN —
          # `Auth.verify_token/1`'s `kind == "api"` WHERE clause is the
          # fail-closed ticket-key boundary this very file exists to pin — so
          # the key now 401s there instead of falling through to the anonymous
          # outcome. Blast radius still "spam, never data"; the door just
          # closed harder.
          keyed in @refusal_statuses and anon not in @refusal_statuses ->
            nil

          true ->
            {route.verb, route.path, [anon: anon, keyed: keyed]}
        end
      end
      |> Enum.reject(&is_nil/1)

    assert offenders == [],
           "a ticket key changed the outcome on these routes (potential elevation):\n" <>
             Enum.map_join(offenders, "\n", &inspect/1)
  end

  test "the boundary has teeth: routes that reject an anon caller reject the key too",
       %{raw: raw} do
    gated = gated_v1_routes()

    # Guard against a vacuous pass — the equality test above is only meaningful
    # if SOME flat /v1 routes genuinely 401/403 an anonymous caller.
    assert gated != [], "expected token-gated /v1 routes to sweep"

    for {verb, path, anon} <- gated do
      keyed = status_for(verb, path, raw)

      assert keyed == anon,
             "#{verb} #{path}: ticket key #{inspect(keyed)} != anon #{inspect(anon)}"
    end
  end

  test "a REVOKED ticket key is rejected on every gated route (like missing)",
       %{key: key, raw: raw, workspace: ws} do
    gated = gated_v1_routes()
    {:ok, _} = Keys.revoke(key.id, ws.id)

    for {verb, path, _anon} <- gated do
      assert status_for(verb, path, raw) in [401, 403]
    end
  end

  test "ROTATE kills the old secret instantly", %{key: key, raw: old_raw, workspace: ws} do
    gated = gated_v1_routes()
    {:ok, %{raw: new_raw}} = Keys.rotate(key.id, ws.id)

    # Context-level: the old secret no longer resolves; the new one does.
    assert {:error, :unauthorized} = Keys.verify(old_raw)
    assert {:ok, _} = Keys.verify(new_raw)

    # Route-level: the old secret is inert on gated routes.
    for {verb, path, _anon} <- gated do
      assert status_for(verb, path, old_raw) in [401, 403]
    end
  end

  test "a PAUSED key is a distinguishable 403 at the RequireTicketKey gate",
       %{key: key, raw: raw, workspace: ws} do
    {:ok, _} = Keys.pause(key.id, ws.id)

    # No `/v1/tickets` route exists in this worktree, so exercise the gate the
    # exempt prefix will run behind directly. Paused → 403 with the operator
    # message; the SAME plug 401s an unknown/invalid key.
    paused = ticket_gate(raw)
    assert paused.status == 403
    assert Jason.decode!(paused.resp_body)["error"]["message"] =~ "key paused"

    {:ok, _} = Keys.unpause(key.id, ws.id)
    live = ticket_gate(raw)
    refute live.halted
    assert live.assigns[:ticket_key].id == key.id

    missing = ticket_gate(nil)
    assert missing.status == 401
  end

  test "Auth.verify_token/1 NEVER returns a ticket-kind row", %{raw: raw} do
    assert {:error, :unauthorized} = Auth.verify_token(raw)
  end

  # ── sweep helpers ────────────────────────────────────────────────────────

  defp sweepable_routes do
    BarkparkWeb.Router.__routes__()
    |> Enum.filter(&(&1.verb in @http_verbs))
  end

  # Substitute dummy values for `:param` and `*glob` path segments so a concrete
  # request URL can be built for a parameterised route.
  defp concrete_path(template) do
    template
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "x"
      "*" <> _ -> "x"
      seg -> seg
    end)
  end

  defp exempt?(path) do
    Enum.any?(@exempt_prefixes, &String.starts_with?(path, &1)) and
      not Enum.any?(@never_exempt_prefixes, &String.starts_with?(path, &1))
  end

  # The flat (non-tenant-scoped) `/v1` routes that reject an ANONYMOUS caller
  # with 401/403 — i.e. the token-gated surface, derived from BEHAVIOR rather
  # than pipeline metadata (`__routes__/0` does not expose `pipe_through`).
  # Scoped `/w/:ws/...` mirrors are excluded: their ResolveWorkspace step fails
  # on the dummy slug BEFORE the token gate, muddying the 401/403 signal — the
  # equality sweep already covers them. Returns `{verb, concrete_path, anon}`.
  defp gated_v1_routes do
    for route <- sweepable_routes(),
        String.starts_with?(route.path, "/v1/"),
        not exempt?(route.path),
        path = concrete_path(route.path),
        anon = status_for(route.verb, path, nil),
        anon in [401, 403],
        do: {route.verb, path, anon}
  end

  # Issue `verb path` with an optional Bearer; return the HTTP status, or
  # `:raised` when the (auth-agnostic) controller blows up on dummy params — both
  # the anon and keyed passes hit the identical code path, so `:raised == :raised`
  # still proves no elevation.
  defp status_for(verb, path, token) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    try do
      dispatch(conn, @endpoint, verb_method(verb), path).status
    rescue
      _ -> :raised
    catch
      _, _ -> :raised
    end
  end

  # Drive the RequireTicketKey plug directly (the gate the `/v1/tickets` exempt
  # prefix runs behind once the sibling slice adds its routes).
  defp ticket_gate(token) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    BarkparkWeb.Plugs.RequireTicketKey.call(conn, [])
  end

  defp verb_method(verb), do: verb |> Atom.to_string() |> String.upcase()
end
