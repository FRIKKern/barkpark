defmodule BarkparkWeb.TokenRootWriteGateTest do
  @moduledoc """
  Fail-before protective test for task-a87a3346b8ff736a — a token minted with
  `permissions: ["read"]` could MUTATE task, ticket and fleet state.

  ## The mechanism

  The `:token_root` plugin bucket mounted at
  `scope "/v1" do pipe_through([:api, :require_token]) end`. `:require_token` is
  `RequireToken` + `PublicRead`, and `PublicRead` no-ops for every token that is
  not `public-read` — so between "a token exists" and the controller there was
  nothing at all. Every `{:post, …, auth: :token_root}` spec in
  `Barkpark.Plugins.Tasks.register_routes/1` and
  `Barkpark.Plugins.Tickets.register_routes/1` was therefore writable by the
  WEAKEST grantable credential: `POST /v1/tokens` mints only `public-read` and
  `read`, and a workspace `member`'s PAT caps at `read`.

  `Plugs.RequireWriteForMutation` closes the bucket by METHOD, not by route —
  the routes are contributed at compile time by `register_routes/1`, so the
  router never names them and a per-route `:require_write` would leave the NEXT
  mutating spec ungated by omission.

  ## Why the assertions are on STATE, not only on status

  The defect answered 200 and the state change landed. A test that only asserts
  403 would still pass against a gate that refuses AFTER the controller has
  written. Every mutation case below re-reads the row and asserts it is
  unchanged.

  RED on origin/main (every mutation returns 200 and the row moves); GREEN with
  the gate mounted.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Registry
  alias BarkparkWeb.Plugs.RequireWriteForMutation

  @dataset "production"
  @read_token "token-root-gate-read"
  @write_token "token-root-gate-write"
  @public_read_token "token-root-gate-public-read"

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_task_schemas!(scope)

    # All three tokens are bound to the SAME workspace, so nothing here can pass
    # or fail for a tenancy reason — the only variable is `permissions`.
    {:ok, _} = Auth.create_token(@read_token, "gate-read", @dataset, ["read"], ws.id)
    {:ok, _} = Auth.create_token(@write_token, "gate-write", @dataset, ["write"], ws.id)
    {:ok, _} = Auth.create_token(@public_read_token, "gate-pub", @dataset, ["public-read"], ws.id)

    %{scope: scope, ws: ws, project: project}
  end

  defp register_task_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_task!(scope) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => uniq("gate"),
          "title" => "gate probe",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "c1", "met" => false, "evidence" => ""}]
          }
        },
        @dataset,
        scope
      )

    task
  end

  defp reload!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  # Claim over the REAL route with a write token and return the live epoch. The
  # epoch is read from the response the server just produced, never re-derived
  # from a context call — a stamp/close body carrying a stale epoch is refused
  # 409 by the fence, which would make the refusal below prove nothing about
  # permissions.
  defp claim_over_http!(conn, doc_id, worker_id) do
    resp =
      conn
      |> authed(@write_token)
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(%{worker_id: worker_id}))

    assert resp.status == 200, "setup claim failed: #{resp.status} #{resp.resp_body}"

    epoch = resp.resp_body |> Jason.decode!() |> get_in(["doc", "claim", "epoch"])
    assert is_integer(epoch), "setup claim returned no epoch: #{resp.resp_body}"
    epoch
  end

  # ── The defect, verb by verb ──────────────────────────────────

  describe "a read-only token cannot mutate the :token_root surface" do
    test "POST /v1/tasks/:doc_id/claim is refused and the row does not move",
         %{conn: conn, scope: scope} do
      task = open_task!(scope)

      resp =
        conn
        |> authed(@read_token)
        |> post("/v1/tasks/#{task.doc_id}/claim", Jason.encode!(%{worker_id: "readonly-probe"}))

      assert resp.status == 403

      after_doc = reload!(task.doc_id, scope)
      assert get_in(after_doc.content, ["lifecycle_status"]) == "open"
      assert get_in(after_doc.content, ["claim"]) in [nil, %{}]
      assert get_in(after_doc.content, ["assignee"]) in [nil, ""]
    end

    test "POST /v1/tasks/:doc_id/stamp cannot forge the one-way `met` lock",
         %{conn: conn, scope: scope} do
      # The task is claimed by a LEGITIMATE write-token holder first, and the
      # stamp body carries that holder's worker_id and live epoch — so the only
      # thing standing between this request and a successful stamp is the write
      # gate. Without it the request 200s and `met` flips to true; a body that
      # 400s on shape would make this assertion vacuous.
      task = open_task!(scope)
      epoch = claim_over_http!(conn, task.doc_id, "legit-worker")

      body =
        Jason.encode!(%{
          worker_id: "legit-worker",
          observed_epoch: epoch,
          criterion: 0,
          # The stamp guard demands the criterion's exact stored wording AND
          # non-empty evidence; without both the request 409s on SHAPE, and the
          # `met == false` assertion below would then hold for the wrong reason.
          criterion_text: "c1",
          met: true,
          evidence: "forged by a read-only token"
        })

      resp = conn |> authed(@read_token) |> post("/v1/tasks/#{task.doc_id}/stamp", body)

      assert resp.status == 403

      [criterion | _] = reload!(task.doc_id, scope).content["acceptance_criteria"]
      assert criterion["met"] == false
      assert criterion["evidence"] == ""
    end

    test "POST /v1/tasks/:doc_id/close is refused and the lifecycle does not move",
         %{conn: conn, scope: scope} do
      task = open_task!(scope)
      epoch = claim_over_http!(conn, task.doc_id, "legit-worker")

      resp =
        conn
        |> authed(@read_token)
        |> post(
          "/v1/tasks/#{task.doc_id}/close",
          # `criteria_override` is required because criterion 0 is unmet — a
          # close without it 409s on the criteria gate, never on permissions.
          Jason.encode!(%{
            worker_id: "legit-worker",
            observed_epoch: epoch,
            criteria_override: "closed by a read-only token"
          })
        )

      assert resp.status == 403
      assert reload!(task.doc_id, scope).content["lifecycle_status"] == "in_progress"
    end

    test "POST /v1/tasks/claim (the queue-wide claim) is refused",
         %{conn: conn, scope: scope} do
      task = open_task!(scope)

      resp =
        conn
        |> authed(@read_token)
        |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "readonly-probe"}))

      assert resp.status == 403
      assert reload!(task.doc_id, scope).content["lifecycle_status"] == "open"
    end

    test "POST /v1/fleet/beat is refused and registers no listener", %{conn: conn} do
      # `worker`, not `worker_id` — Fleet.beat/3 400s on the wrong key, and a 400
      # would pass a bare `!= 200` assertion while proving nothing.
      resp =
        conn
        |> authed(@read_token)
        |> post("/v1/fleet/beat", Jason.encode!(%{worker: "readonly-probe"}))

      assert resp.status == 403

      roster = conn |> authed(@write_token) |> get("/v1/fleet/roster")

      workers =
        roster.resp_body
        |> Jason.decode!()
        |> Map.get("documents", [])
        |> Enum.map(& &1["worker"])

      refute "readonly-probe" in workers,
             "the refused beat still registered a listener — the gate must halt BEFORE " <>
               "the controller writes (roster: #{inspect(workers)})"
    end
  end

  # ── The controls: the gate must not over-refuse ───────────────────────────

  describe "controls — what the gate must NOT change" do
    test "a `write` token still claims a task (200, and the row moves)",
         %{conn: conn, scope: scope} do
      task = open_task!(scope)

      resp =
        conn
        |> authed(@write_token)
        |> post("/v1/tasks/#{task.doc_id}/claim", Jason.encode!(%{worker_id: "legit-worker"}))

      assert resp.status == 200
      assert reload!(task.doc_id, scope).content["lifecycle_status"] == "in_progress"
    end

    test "a `read` token keeps every :token_root READ it had", %{conn: conn, scope: scope} do
      _task = open_task!(scope)

      for path <- ["/v1/tasks", "/v1/tasks/ready", "/v1/fleet/roster"] do
        resp = conn |> authed(@read_token) |> get(path)

        assert resp.status == 200,
               "GET #{path} answered #{resp.status} for a read token — the write gate " <>
                 "must pass safe methods through untouched"
      end
    end

    test "a `public-read` token is still refused by PublicRead, not by this gate",
         %{conn: conn} do
      # The tier BELOW read was already clamped on every method including GET.
      # If this ever answers 200 the PublicRead clamp regressed.
      resp = conn |> authed(@public_read_token) |> get("/v1/tasks/ready")
      assert resp.status == 403
    end
  end

  # ── The census: no mutating route on this bucket may be ungated ───────────

  describe "route census — the bucket is closed by construction" do
    test "the bucket carries BOTH reads and writes, so the gate is not a blanket refusal" do
      specs = token_root_specs()

      refute specs == [],
             "no plugin contributes an `auth: :token_root` route — this census is " <>
               "vacuous. Fix the collector, do not delete the assertion."

      {safe, mutating} =
        Enum.split_with(specs, &(spec_method(&1) in RequireWriteForMutation.safe_methods()))

      refute mutating == [],
             "the :token_root bucket has no mutating spec — either the tasks/tickets " <>
               "plugins stopped contributing writes, or this census stopped seeing them"

      refute safe == [],
             "the :token_root bucket has no READ spec — if that were true the gate would " <>
               "be indistinguishable from a blanket :require_write and the GET controls " <>
               "above would prove nothing"
    end

    test "the mount that expands the bucket runs the write gate, after the token check" do
      # Block-scoped on the `plugin_routes(scope: :token_root)` mount, not
      # line-anchored: inserting lines anywhere in router.ex cannot slide it.
      # `Router.__routes__/0` cannot answer this — it carries no :pipe_through.
      pipes = token_root_mount_pipes()

      assert String.contains?(pipes, "RequireWriteForMutation"),
             "the :token_root mount does not run the write gate — every POST the tasks " <>
               "and tickets plugins contribute is writable by a read-only token " <>
               "(task-a87a3346b8ff736a). pipe_through: #{pipes}"

      assert offset_of!(pipes, ":require_token") < offset_of!(pipes, "RequireWriteForMutation"),
             ":require_token must assign :api_token before the write gate reads it — " <>
               "pipe_through: #{pipes}"
    end

    test "safe methods are exactly GET/HEAD/OPTIONS" do
      # Asserted against the plug's own list so a change there is visible here
      # rather than silently widening what passes ungated.
      assert RequireWriteForMutation.safe_methods() == ~w(GET HEAD OPTIONS)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # The same collector `plugin_routes(scope: :token_root)` expands at compile
  # time, so this census sees exactly what the router mounts.
  defp token_root_specs do
    %{scope: :token_root, phase: :compile}
    |> Registry.collect_routes()
    |> Enum.filter(fn
      {_verb, _path, _mod, _action, opts} -> Keyword.get(opts, :auth) == :token_root
      _ -> false
    end)
  end

  defp spec_method({verb, _, _, _, _}), do: verb |> to_string() |> String.upcase()

  defp token_root_mount_pipes do
    src = File.read!(@router_path)

    case Regex.run(
           ~r/scope "\/v1" do\n\s*pipe_through\((.+?)\)\n\n\s*plugin_routes\(scope: :token_root\)/,
           src
         ) do
      [_, pipes] ->
        pipes

      _ ->
        flunk(
          "router.ex no longer mounts `plugin_routes(scope: :token_root)` behind a " <>
            "pipe_through — the census cannot see the bucket's pipeline"
        )
    end
  end

  defp offset_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} is not in the :token_root pipe_through: #{haystack}")
    end
  end
end
