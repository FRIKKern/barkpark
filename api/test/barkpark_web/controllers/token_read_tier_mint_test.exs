defmodule BarkparkWeb.TokenReadTierMintTest do
  @moduledoc """
  gfr-bl-read-tier-token-mint-surface — the `read` tier, minted through the ONLY
  endpoint a customer can reach, proved to do exactly what it claims and nothing
  more.

  ## What was actually broken, and what was not

  The field report read as "private schemas are unreadable by any token". At the
  AUTHORIZATION layer that is false, and this file is the proof: a token minted
  with `["read"]` reads a private schema today. `PublicRead.public_read_token?/1`
  is a membership test on the literal string `"public-read"`, so a `["read"]`
  token no-ops out of the public clamp and `QueryController.authed?/1` treats it
  as authenticated. There was never anything to unclamp — a change that loosened
  the allowlist would have been a pure regression.

  What WAS broken is the MINTING surface, and it is a client-side defect: the
  manifest declares `token.create --permissions` as a comma list, but the CLI
  serializes a non-batch write's flags as query parameters, so `--permissions
  read` arrives as the STRING `"read"` rather than a list. `fetch_permissions/1`
  matches only `is_list(perms)`, so that request 422s and the caller silently
  falls back to `public-read`. The last test below is that shape, pinned here so
  the server half of the contract is stated where the tier lives: a list mints,
  a scalar is refused, and neither is a silent default.

  ## Why the sibling-workspace arm is not decoration

  The read tier is only safe because it is WORKSPACE-BOUND. `Auth.create_token/5`
  with a `workspace_id` writes the membership row that scopes it, and a scoped
  read into a workspace the token holds no seat in must fail. Without that arm,
  "the read tier reads private schemas" is an argument for not shipping it.

  Test-only file: it changes nothing under `api/lib`. The CLI half of this task
  lives in `internal/cli/token_create_cmd.go`.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0, create_project!: 1]

  alias Barkpark.{Auth, Content}

  # The SAME dataset string on both sides: isolation must come from the resolved
  # workspace, never from the dataset leaf.
  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    private_a = seed_private_schema!(scope_a, "vault_a")
    private_b = seed_private_schema!(scope_b, "vault_b")

    # An admin OF A — `Auth.create_token/5` with a workspace_id also writes the
    # owner/admin membership row `:scoped_admin`'s RequireWorkspaceRole reads, so
    # this token is legitimately allowed to MINT in A and nowhere else.
    admin_a = mint_raw("gfr-read-tier-admin-a")

    {:ok, _} =
      Auth.create_token(admin_a, "admin of A", @dataset, ["read", "write", "admin"], ws_a.id)

    %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      private_a: private_a,
      private_b: private_b,
      admin_a: admin_a
    }
  end

  defp mint_raw(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PRIVATE schema — the whole point. Unique names: the test database is shared
  # across lanes and a fixed name collides on (name, dataset_id).
  defp seed_private_schema!(scope, prefix) do
    name = "#{prefix}_#{System.unique_integer([:positive])}"

    {:ok, schema} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "private", "fields" => []},
        @dataset,
        scope
      )

    schema.name
  end

  defp bearer(conn, raw) do
    conn
    |> Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
  end

  defp query_path(ws, proj, type),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/query/#{@dataset}/#{type}"

  # Mint through the endpoint a customer reaches: POST to the SCOPED route, as an
  # admin of that workspace, with `permissions` as a LIST.
  defp mint_read_token!(conn, admin_raw, ws, proj, permissions) do
    body =
      conn
      |> bearer(admin_raw)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/tokens", %{
        "label" => "desk reader #{System.unique_integer([:positive])}",
        "permissions" => permissions,
        "dataset" => @dataset
      })
      |> json_response(201)

    body
  end

  test "THE FIXTURE IS NOT VACUOUS: the private schema is invisible to an anonymous reader",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, private_a: private_a} do
    # If this were 200, every assertion below would pass for a schema that was
    # never private and the file would prove nothing.
    resp = get(Phoenix.ConnTest.build_conn(conn), query_path(ws_a, proj_a, private_a))

    assert resp.status == 404,
           "an anonymous read of #{private_a} answered #{resp.status} — the fixture schema is " <>
             "not actually private, so the read-tier arms below are vacuous"
  end

  test "a token minted with [\"read\"] READS a private schema in its OWN workspace",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, private_a: private_a, admin_a: admin_a} do
    receipt = mint_read_token!(conn, admin_a, ws_a, proj_a, ["read"])

    # The receipt must SAY read — a mint that silently landed public-read would
    # otherwise pass the read below only because of some other credential.
    assert receipt["permissions"] == ["read"],
           "the mint receipt says #{inspect(receipt["permissions"])} — the requested tier did not land"

    assert receipt["workspace"] == ws_a.slug,
           "the token was bound to #{inspect(receipt["workspace"])}, not to the workspace the " <>
             "request was scoped to (#{ws_a.slug}) — a mint that lands in Default is the " <>
             "silent failure this endpoint exists to avoid"

    resp = get(bearer(conn, receipt["token"]), query_path(ws_a, proj_a, private_a))

    assert resp.status == 200,
           "the [\"read\"] token was refused (#{resp.status}) on its OWN workspace's private " <>
             "schema — this is the claim the field report made, and it must stay false"
  end

  test "the SAME minted token cannot read a SIBLING workspace's private schema",
       %{
         conn: conn,
         ws_a: ws_a,
         proj_a: proj_a,
         ws_b: ws_b,
         proj_b: proj_b,
         private_b: private_b,
         admin_a: admin_a
       } do
    receipt = mint_read_token!(conn, admin_a, ws_a, proj_a, ["read"])

    resp = get(bearer(conn, receipt["token"]), query_path(ws_b, proj_b, private_b))

    assert resp.status in [403, 404],
           "a workspace-A [\"read\"] token answered #{resp.status} on workspace B's PRIVATE " <>
             "schema #{private_b} — the read tier is only shippable because it is " <>
             "workspace-bound, and this is the boundary"
  end

  test "public-read stays the DEFAULT, and it does NOT read a private schema",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, private_a: private_a, admin_a: admin_a} do
    # Both halves of the tier split in one place: the default is unchanged (a
    # caller who names nothing still gets public-read), and public-read is
    # genuinely narrower than read — otherwise the new verb buys nothing.
    body =
      conn
      |> bearer(admin_a)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/w/#{ws_a.slug}/p/#{proj_a.slug}/v1/tokens", %{
        "label" => "site #{System.unique_integer([:positive])}",
        "dataset" => @dataset
      })
      |> json_response(201)

    assert body["permissions"] == ["public-read"],
           "the unstated default moved to #{inspect(body["permissions"])}"

    resp = get(bearer(conn, body["token"]), query_path(ws_a, proj_a, private_a))

    assert resp.status == 404,
           "a public-read token read the private schema (#{resp.status}) — the two tiers are " <>
             "not distinguishable and the read tier is pointless"
  end

  test "THE MINTING GAP: a SCALAR permissions value is refused, so a query-string flag cannot mint",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, admin_a: admin_a} do
    # This is the exact shape the manifest CLI path puts on the wire:
    # `?permissions=read`, which Phoenix merges into params as a BINARY.
    # fetch_permissions/1 accepts only a list, so the request 422s — which is why
    # no surface could ask for the read tier until `bp token create
    # --permissions` (internal/cli/token_create_cmd.go) sent it as a JSON array.
    resp =
      conn
      |> bearer(admin_a)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/w/#{ws_a.slug}/p/#{proj_a.slug}/v1/tokens?permissions=read", %{
        "label" => "scalar #{System.unique_integer([:positive])}",
        "dataset" => @dataset
      })

    assert resp.status == 422,
           "a scalar `permissions` answered #{resp.status} — if this is now accepted the CLI's " <>
             "query-string flag mints after all, and the built-in's gate can be revisited"

    body = json_response(resp, 422)

    assert body["error"]["message"] =~ "not allowed",
           "the refusal does not explain itself: #{inspect(body)}"
  end

  test "the read-only allowlist still refuses a privilege mint",
       %{conn: conn, ws_a: ws_a, proj_a: proj_a, admin_a: admin_a} do
    # The new surface must not have widened what an admin can mint. `write` is
    # the one that would turn a read-token verb into a privilege escalation.
    resp =
      conn
      |> bearer(admin_a)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/w/#{ws_a.slug}/p/#{proj_a.slug}/v1/tokens", %{
        "label" => "escalate #{System.unique_integer([:positive])}",
        "permissions" => ["read", "write"],
        "dataset" => @dataset
      })

    assert resp.status == 422,
           "[\"read\",\"write\"] minted (#{resp.status}) — the read-only allowlist is gone"
  end
end
