defmodule BarkparkWeb.PluginTokenBucketWriteGateTest do
  @moduledoc """
  Fail-before protective test for task-wb-api-plugin-token-bucket-write-gate —
  a token minted with `permissions: ["read"]` could MUTATE through the
  `:token` plugin route bucket (BOTH the flat `/v1/plugins` mount and its
  scoped `/w/:ws/p/:proj/v1/plugins` mirror).

  ## The mechanism

  `scope "/v1/plugins" do pipe_through([:api, :require_token]) end` mounts
  every plugin-contributed `auth: :token` route. `:require_token` is
  `RequireToken` + `PublicRead`, and `PublicRead` no-ops for every token that
  is not `public-read` — so between "a token exists" and the controller there
  was nothing at all. The github plugin's
  `{:post, "/github/adopt/:id", …, auth: :token}` is therefore writable by the
  WEAKEST grantable credential: `POST /v1/tokens` mints only `public-read` and
  `read`, and a workspace `member`'s PAT caps at `read`.

  `Plugs.RequireWriteForMutation` closes the bucket by METHOD, not by route —
  the routes are contributed at compile time by `register_routes/1`, so the
  router never names them and a per-route `:require_write` would leave the
  NEXT mutating spec ungated by omission. This is the SAME fix already applied
  to the sibling `:token_root` bucket under task-a87a3346b8ff736a
  (`test/barkpark_web/token_root_write_gate_test.exs`); this file is built on
  that test's fixture shape.

  ## Why the assertions are on STATE, not only on status

  The defect answered 200 and the state change landed. A test that only
  asserts 403 would still pass against a gate that refuses AFTER the
  controller has written. The adopt case re-reads the task and asserts
  `content.github.state` is still `"intake"`.

  RED on origin/main (the read-token adopt returns 200 and the row flips to
  `"adopted"`); GREEN with the gate mounted.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Registry
  alias BarkparkWeb.Plugs.RequireWriteForMutation

  @dataset "production"
  @read_token "plugin-token-bucket-gate-read"
  @write_token "plugin-token-bucket-gate-write"

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_task_schemas!(scope)

    # Both tokens are bound to the SAME workspace, so nothing here can pass or
    # fail for a tenancy reason — the only variable is `permissions`.
    {:ok, _} = Auth.create_token(@read_token, "gate-read", @dataset, ["read"], ws.id)
    {:ok, _} = Auth.create_token(@write_token, "gate-write", @dataset, ["write"], ws.id)

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

  # An unclaimed `src:github` intake task, exactly the shape Wave 3 births —
  # `content.github.state == "intake"` is the only fact `Adopt.adopt/3` reads
  # to decide adoptability.
  defp open_intake_task!(scope) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => uniq("gh-gate"),
          "title" => "gate probe intake",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "labels" => ["src:github", "needs-human"],
            "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 1, "state" => "intake"}
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

  defp github_state(doc), do: get_in(doc.content, ["github", "state"])

  # ── The defect: a read-only token through the flat `:token` bucket ────────

  describe "a read-only token cannot mutate through the flat /v1/plugins :token bucket" do
    test "POST /v1/plugins/github/adopt/:id is refused and the task stays intake",
         %{conn: conn, scope: scope} do
      task = open_intake_task!(scope)

      resp =
        conn
        |> authed(@read_token)
        |> post("/v1/plugins/github/adopt/#{task.doc_id}", Jason.encode!(%{}))

      assert resp.status == 403

      assert github_state(reload!(task.doc_id, scope)) == "intake"
    end
  end

  # ── The control: a write token still adopts (the gate is not a blanket refusal) ─

  describe "controls — what the gate must NOT change" do
    test "a `write` token still adopts a src:github intake task (200, state flips)",
         %{conn: conn, scope: scope} do
      task = open_intake_task!(scope)

      resp =
        conn
        |> authed(@write_token)
        |> post("/v1/plugins/github/adopt/#{task.doc_id}", Jason.encode!(%{}))

      assert resp.status == 200
      assert github_state(reload!(task.doc_id, scope)) == "adopted"
    end

    test "a `read` token still keeps GET /v1/plugins/github/status", %{conn: conn} do
      resp = conn |> authed(@read_token) |> get("/v1/plugins/github/status")

      assert resp.status == 200,
             "GET /v1/plugins/github/status answered #{resp.status} for a read token — " <>
               "the write gate must pass safe methods through untouched"
    end

    # Sibling-carve-out proof (not this bucket's mount): the gate is added to
    # the `:token` SCOPE's own pipe_through, never hoisted into the shared
    # `:require_token` pipeline definition — so a read token still self-revokes
    # over `DELETE /v1/auth/app-tokens/current`, a DIFFERENT `/v1/auth` scope
    # that also runs `[:api, :require_token]`.
    test "a `read` token still self-revokes via DELETE /v1/auth/app-tokens/current",
         %{conn: conn} do
      resp = conn |> authed(@read_token) |> delete("/v1/auth/app-tokens/current")

      assert %{"revoked" => true} = json_response(resp, 200)
    end
  end

  # ── The census: both :token mounts run the write gate ──────────────────────

  describe "route census — both :token mounts are closed by construction" do
    test "the bucket carries both reads and writes, so the gate is not a blanket refusal" do
      specs = token_specs()

      refute specs == [],
             "no plugin contributes an `auth: :token` route — this census is vacuous. " <>
               "Fix the collector, do not delete the assertion."

      {safe, mutating} =
        Enum.split_with(specs, &(spec_method(&1) in RequireWriteForMutation.safe_methods()))

      refute mutating == [],
             "the :token bucket has no mutating spec — the github plugin stopped " <>
               "contributing `POST /github/adopt/:id`, or this census stopped seeing it"

      refute safe == [],
             "the :token bucket has no READ spec — if that were true the gate would be " <>
               "indistinguishable from a blanket :require_write and the GET control above " <>
               "would prove nothing"
    end

    test "the flat /v1/plugins mount runs the write gate, after the token check" do
      pipes = flat_token_mount_pipes()

      assert String.contains?(pipes, "RequireWriteForMutation"),
             "the flat /v1/plugins :token mount does not run the write gate — every POST " <>
               "a plugin contributes at auth: :token is writable by a read-only token " <>
               "(task-wb-api-plugin-token-bucket-write-gate). pipe_through: #{pipes}"

      assert offset_of!(pipes, ":require_token") < offset_of!(pipes, "RequireWriteForMutation"),
             ":require_token must assign :api_token before the write gate reads it — " <>
               "pipe_through: #{pipes}"
    end

    test "the scoped /w/:ws/p/:proj/v1/plugins mirror runs the write gate, after the token check" do
      pipes = scoped_token_mount_pipes()

      assert String.contains?(pipes, "RequireWriteForMutation"),
             "the scoped /w/:ws/p/:proj/v1/plugins :token mount does not run the write " <>
               "gate — a read-only token can mutate through the tenancy-aware mirror " <>
               "(task-wb-api-plugin-token-bucket-write-gate). pipe_through: #{pipes}"

      assert offset_of!(pipes, ":require_token") < offset_of!(pipes, "RequireWriteForMutation"),
             ":require_token must assign :api_token before the write gate reads it — " <>
               "pipe_through: #{pipes}"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # The same collector `plugin_routes(scope: :token)` expands at compile time,
  # so this census sees exactly what both router mounts contribute.
  defp token_specs do
    %{scope: :token, phase: :compile}
    |> Registry.collect_routes()
    |> Enum.filter(fn
      {_verb, _path, _mod, _action, opts} -> Keyword.get(opts, :auth) == :token
      _ -> false
    end)
  end

  defp spec_method({verb, _, _, _, _}), do: verb |> to_string() |> String.upcase()

  defp flat_token_mount_pipes do
    src = File.read!(@router_path)

    case Regex.run(
           ~r/scope "\/v1\/plugins" do\n\s*pipe_through\((.+?)\)\n\n\s*plugin_routes\(scope: :token\)/,
           src
         ) do
      [_, pipes] ->
        pipes

      _ ->
        flunk(
          "router.ex no longer mounts the flat `plugin_routes(scope: :token)` behind a " <>
            "pipe_through — the census cannot see the bucket's pipeline"
        )
    end
  end

  defp scoped_token_mount_pipes do
    src = File.read!(@router_path)

    case Regex.run(
           ~r/scope "\/w\/:workspace_slug\/p\/:project_slug\/v1\/plugins" do\n\s*pipe_through\((.+?)\)\n\n\s*plugin_routes\(scope: :token\)/,
           src
         ) do
      [_, pipes] ->
        pipes

      _ ->
        flunk(
          "router.ex no longer mounts the scoped `plugin_routes(scope: :token)` mirror " <>
            "behind a pipe_through — the census cannot see the bucket's pipeline"
        )
    end
  end

  defp offset_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} is not in the :token pipe_through: #{haystack}")
    end
  end
end
