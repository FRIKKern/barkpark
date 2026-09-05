defmodule BarkparkWeb.Plugs.RequirePlatformOperatorTest do
  @moduledoc """
  `task-c7e2b87f1bbca815` criterion 1 — THE INSTANCE-OPERATOR TIER, run.

  THE RULING (orchestrator, under the owner's delegated authority; owner
  informed 2026-09-01, refined 2026-09-02), quoted verbatim:

  > "A: api/ grows ONE config-backed operator allowlist plug mirroring cloud's
  > PLATFORM_ADMIN_EMAILS shape: env BARKPARK_OPERATOR_EMAILS (comma list;
  > matched against the bearer's owner email — PAT owner_user_id→email, app
  > token label \"app:<email>\") plus BARKPARK_OPERATOR_TOKEN_IDS (explicit
  > ids). UNSET → legacy behaviour (admin bit suffices) AND a startup warning
  > naming the seven routes; SET → allowlist only, fail closed. Same plug
  > guards all seven instance-global routes; workspace-scoped admin routes
  > untouched."

  THE FIXTURE the criterion asks for, exactly: TWO workspaces; an
  admin-permissioned token seated ONLY in workspace A (`Auth.create_token/5`
  with `["read","write","admin"]` and `ws_a.id`, which writes the membership
  row); a SECOND principal (B's admin) writes a global run-secret through
  `PUT /v1/secrets/<name>`; and A's admin then reads it.

  The refusal is by an EXPLICIT operator predicate applied to the caller's
  token (`BarkparkWeb.Plugs.RequirePlatformOperator`, mounted on the
  `[:api, :require_admin, :require_platform_operator]` pipeline), NEVER by
  re-pointing `SecretController.resolve_scope/1` at
  `conn.assigns[:current_workspace]` — which would delete the global tier
  instead of fencing it. `resolve_scope/1` is untouched by this PR, and the
  legacy arm below proves the global tier still exists and still serves.

  THE MATRIX (allowlist UNSET × SET, × four principals):

  | principal              | UNSET            | SET (armed)        |
  |------------------------|------------------|--------------------|
  | admin seated only in A | 200 (legacy)     | 403 on ALL SEVEN   |
  | operator (id-listed)   | 200              | 200                |
  | operator (email: PAT)  | 200              | 200                |
  | operator (email: app:) | 200              | 200                |
  | anonymous              | 401              | 401 (RequireToken) |

  Both arms are asserted because a one-sided test cannot tell "the gate works"
  from "the route is broken": the UNSET row is the non-vacuity control for the
  SET row, and vice versa.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import ExUnit.CaptureLog

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Repo
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  @dataset "production"
  @password "correct-horse-battery-staple"

  setup :reset_rate_limiter!

  setup do
    # Deterministic baseline: the shared test node inherits whatever
    # runtime.exs read from the environment, so pin BOTH keys to UNSET and
    # restore them afterwards. Without this a developer (or a CI box) with
    # BARKPARK_OPERATOR_EMAILS exported would silently invert every arm.
    put_allowlist([], [])

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # THE PRINCIPAL UNDER TEST: admin permission, membership in A ONLY.
    raw_a = uniq("adm-a")
    {:ok, _tok_a} = admin_token(raw_a, uniq("lbl-a"), ws_a.id)

    # THE SECOND PRINCIPAL: writes the global secret A's admin then reads.
    raw_b = uniq("adm-b")
    {:ok, _tok_b} = admin_token(raw_b, uniq("lbl-b"), ws_b.id)

    # OPERATOR 1 — admitted by BARKPARK_OPERATOR_TOKEN_IDS (the token row id).
    raw_op_id = uniq("op-id")
    {:ok, tok_op_id} = admin_token(raw_op_id, uniq("lbl-op-id"), ws_a.id)

    # OPERATOR 2 — admitted by BARKPARK_OPERATOR_EMAILS through a PAT's
    # owner_user_id -> Accounts user -> email.
    {:ok, user} =
      Accounts.register_user(%{email: uniq("op-pat") <> "@example.com", password: @password})

    raw_op_pat = uniq("op-pat-tok")
    {:ok, tok_op_pat} = admin_token(raw_op_pat, uniq("lbl-op-pat"), ws_a.id)

    _ =
      tok_op_pat
      |> Ecto.Changeset.change(owner_user_id: user.id)
      |> Repo.update!()

    # OPERATOR 3 — admitted by BARKPARK_OPERATOR_EMAILS through the app-token
    # label convention `app:<email>` (the same one
    # Auth.revoke_app_tokens_for_email/2 matches on).
    app_email = uniq("op-app") <> "@example.com"
    raw_op_app = uniq("op-app-tok")
    {:ok, _tok_op_app} = admin_token(raw_op_app, "app:" <> app_email, ws_a.id)

    # The global secret, written by the SECOND principal while the allowlist is
    # still UNSET (i.e. through the legacy door this PR keeps open).
    secret = uniq("probe_secret")
    value = uniq("v")
    wrote = put(as(raw_b), "/v1/secrets/#{secret}", Jason.encode!(%{value: value}))
    assert wrote.status == 200, "setup secret write failed: #{wrote.resp_body}"

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_a: raw_a,
      admin_b: raw_b,
      op_id: raw_op_id,
      op_id_token: tok_op_id,
      op_pat: raw_op_pat,
      op_pat_email: user.email,
      op_app: raw_op_app,
      op_app_email: app_email,
      secret: secret,
      value: value
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp admin_token(raw, label, ws_id),
    do: Auth.create_token(raw, label, @dataset, ["read", "write", "admin"], ws_id)

  defp as(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  defp anon do
    scoped_conn() |> put_req_header("content-type", "application/json")
  end

  # Arm/disarm the allowlist through Application env (the same key the plug
  # reads at RUNTIME), restoring whatever the node booted with.
  defp put_allowlist(emails, ids) do
    prev_emails = Application.get_env(:barkpark, :operator_emails, [])
    prev_ids = Application.get_env(:barkpark, :operator_token_ids, [])

    Application.put_env(:barkpark, :operator_emails, emails)
    Application.put_env(:barkpark, :operator_token_ids, ids)

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_emails)
      Application.put_env(:barkpark, :operator_token_ids, prev_ids)
    end)

    :ok
  end

  # One probe per RULING row — the seven INSTANCE-GLOBAL groups, in the census's
  # own numbering. Every one of them is refused by the PIPELINE, so none reaches
  # a controller and none needs a valid body; `no_side_effect` names the check
  # that proves it for the two mutating probes.
  defp seven_groups(ctx) do
    [
      {"RULING row 1 (operator primitives)", :post, "/v1/admin/rollback", "{}"},
      {"RULING row 2 (plugin roster)", :get, "/v1/plugins", nil},
      {"RULING row 3 (instance plugin settings)", :put,
       "/v1/plugins/settings/#{ctx.probe_plugin}",
       Jason.encode!(%{settings: %{"operator_probe_flag" => true}})},
      {"RULING row 4 (global secret reveal)", :get, "/v1/secrets/#{ctx.secret}", nil},
      {"RULING row 5 (status incidents)", :post, "/v1/status/incidents",
       Jason.encode!(%{title: "probe", body: "probe"})},
      {"RULING row 6 (playground provisioning)", :post, "/api/playground", "{}"},
      {"RULING row 7 (bundle import)", :post, "/api/workspaces/#{ctx.ws_b.slug}/import", "{}"},
      {"group 8 (instance reads: metrics exposition)", :get, "/v1/instance/metrics", nil},
      {"group 8 (instance reads: deploy door)", :get, "/v1/instance/site-deploy", nil}
    ]
  end

  defp send_probe(conn, :get, path, _body), do: get(conn, path)
  defp send_probe(conn, :post, path, body), do: post(conn, path, body)
  defp send_probe(conn, :put, path, body), do: put(conn, path, body)

  # ── UNSET: legacy behaviour, byte-for-byte ─────────────────────────────

  describe "allowlist UNSET (both env vars empty) — LEGACY" do
    test "an admin seated ONLY in A still reads the instance's global secret", ctx do
      body =
        as(ctx.admin_a)
        |> get("/v1/secrets/#{ctx.secret}")
        |> json_response(200)

      assert body["value"] == ctx.value,
             "the legacy arm broke: an unset allowlist must NOT change behaviour"
    end

    test "an admin seated ONLY in A still reaches the read-side instance-global groups", ctx do
      assert get(as(ctx.admin_a), "/v1/plugins").status == 200,
             "RULING row 2 closed on an instance that never opted in"

      assert get(as(ctx.admin_a), "/v1/secrets").status == 200,
             "RULING row 4 (index) closed on an instance that never opted in"
    end

    test "the plug itself is a PASS-THROUGH while unset — the legacy claim for all seven", ctx do
      # The five remaining RULING groups are MUTATING (rollback, incident
      # create, settings write, playground provisioning, bundle import), so
      # firing them for real to prove "not 403" would write instance-wide rows
      # into a test database shared with every other agent. The legacy claim is
      # a property of THE PLUG, which the census asserts is mounted on all
      # seven groups and nowhere else: with the allowlist unset it must not
      # halt, whatever the caller is.
      {:ok, token} = Auth.verify_token(ctx.admin_a)

      conn =
        scoped_conn()
        |> Plug.Conn.assign(:api_token, token)
        |> RequirePlatformOperator.call([])

      refute conn.halted
      assert is_nil(conn.status)
    end

    test "warn_if_unset/0 emits the startup warning naming the seven groups and both env vars" do
      log = capture_log(fn -> assert RequirePlatformOperator.warn_if_unset() == :ok end)

      assert log =~ "[Operator]"
      assert log =~ "BARKPARK_OPERATOR_EMAILS"
      assert log =~ "BARKPARK_OPERATOR_TOKEN_IDS"
      assert log =~ "/v1/secrets/:name"
      assert log =~ "/v1/plugins/settings/:plugin_name"
      assert log =~ "/v1/admin/self-update"
      assert log =~ "/v1/admin/rollback"
      assert log =~ "/v1/admin/site-deploy"
      assert log =~ "/v1/status/incidents"
      assert log =~ "/api/playground"
      assert log =~ "/api/workspaces/:workspace_slug/import"
      assert log =~ "GET /v1/plugins"
      assert log =~ "/v1/instance/site-deploy"
      assert log =~ "/v1/instance/metrics"
    end

    test "the allowlist reads as EMPTY, which is what makes the arm above meaningful" do
      assert RequirePlatformOperator.allowlist() == %{emails: [], token_ids: []}
    end
  end

  # ── SET: allowlist only, fail closed ───────────────────────────────────

  describe "allowlist SET (armed) — the workspace admin is refused" do
    setup ctx do
      # Armed with a principal that is NOT ctx.admin_a: the id of the
      # id-listed operator token, and the two operator EMAILS (upper-cased, to
      # prove the match is case-insensitive on both sides).
      put_allowlist(
        [String.upcase(ctx.op_pat_email), String.upcase(ctx.op_app_email)],
        [ctx.op_id_token.id]
      )

      Map.put(ctx, :probe_plugin, uniq("operator-probe"))
    end

    test "THE CRITERION: GET /v1/secrets/<name> by A's admin is 403", ctx do
      conn = get(as(ctx.admin_a), "/v1/secrets/#{ctx.secret}")

      assert conn.status == 403
      body = json_response(conn, 403)

      assert body["error"]["code"] == "forbidden",
             "the machine key must not fork from RequireAdmin's 403: #{inspect(body)}"

      assert body["error"]["required"] == "platform_operator",
             "the 403 must name the tier it required: #{inspect(body)}"

      refute conn.resp_body =~ ctx.value,
             "the refusal leaked the secret it refused: #{conn.resp_body}"
    end

    test "ALL SEVEN instance-global groups are 403 for A's admin", ctx do
      for {label, method, path, body} <- seven_groups(ctx) do
        conn = send_probe(as(ctx.admin_a), method, path, body)

        assert conn.status == 403,
               "#{label}: #{method} #{path} answered #{conn.status}, not 403 — the operator " <>
                 "gate is not mounted on this group"

        assert conn.resp_body =~ "platform_operator",
               "#{label}: refused, but not by the operator gate: #{conn.resp_body}"
      end
    end

    test "the refusal lands BEFORE the controller — the write probe left no record", ctx do
      written =
        put(
          as(ctx.admin_a),
          "/v1/plugins/settings/#{ctx.probe_plugin}",
          Jason.encode!(%{settings: %{"operator_probe_flag" => true}})
        )

      assert written.status == 403

      # Read it back as a REAL operator: if the refused PUT had still written,
      # this would be a 200 carrying the flag.
      read = get(as(ctx.op_id), "/v1/plugins/settings/#{ctx.probe_plugin}")

      refute read.resp_body =~ "operator_probe_flag",
             "the 403 was cosmetic — the settings record was written anyway: #{read.resp_body}"
    end

    test "an ID-listed operator is served (BARKPARK_OPERATOR_TOKEN_IDS)", ctx do
      body = as(ctx.op_id) |> get("/v1/secrets/#{ctx.secret}") |> json_response(200)
      assert body["value"] == ctx.value

      assert get(as(ctx.op_id), "/v1/plugins").status == 200
    end

    test "an EMAIL-listed operator is served through a PAT's owner_user_id", ctx do
      body = as(ctx.op_pat) |> get("/v1/secrets/#{ctx.secret}") |> json_response(200)
      assert body["value"] == ctx.value
    end

    test "an EMAIL-listed operator is served through an app token's app:<email> label", ctx do
      body = as(ctx.op_app) |> get("/v1/secrets/#{ctx.secret}") |> json_response(200)
      assert body["value"] == ctx.value
    end

    test "anonymous is still 401 — RequireToken, never this plug's 403", ctx do
      conn = get(anon(), "/v1/secrets/#{ctx.secret}")

      assert conn.status == 401
      refute conn.resp_body =~ "platform_operator"
    end

    test "the WORKSPACE-SCOPED admin routes are untouched: A's admin still exports A", ctx do
      conn = get(as(ctx.admin_a), "/api/workspaces/#{ctx.ws_a.slug}/export")

      assert conn.status == 200,
             "the operator allowlist leaked onto a workspace-scoped admin route and locked a " <>
               "tenant admin out of their own workspace (status #{conn.status})"
    end
  end

  # ── The allowlist reader itself ────────────────────────────────────────

  describe "allowlist/0" do
    test "trims, downcases emails and drops blank entries" do
      put_allowlist(["  OPS@Example.COM ", "", "   "], ["  ABC-123  ", ""])

      assert RequirePlatformOperator.allowlist() == %{
               emails: ["ops@example.com"],
               token_ids: ["abc-123"]
             }
    end

    test "a list of only blanks reads as UNSET, so a stray comma cannot arm the tier" do
      put_allowlist([" ", ""], ["", "  "])
      assert RequirePlatformOperator.allowlist() == %{emails: [], token_ids: []}
    end

    test "warn_if_unset/0 is SILENT once either key is armed", ctx do
      put_allowlist([], [ctx.op_id_token.id])
      refute capture_log(fn -> RequirePlatformOperator.warn_if_unset() end) =~ "[Operator]"
    end
  end
end
