defmodule BarkparkWeb.Integration.HaltPathTest do
  @moduledoc """
  Integration probe for the lifecycle-hook halt path (Goal `barkpark-b1m`,
  Task `barkpark-tid`). Pins the contract landed in Goal `barkpark-9lq`
  (commit 2bfc60b): when a plugin's `before_publish` hook returns
  `{:halt, reason}`, `POST /v1/data/mutate/<dataset>` with a publish
  mutation responds **HTTP 409** with the CANONICAL error envelope
  `{"error":{"code":"halted","message":"<reason>","request_id":…,"hint":…}}`,
  and the draft remains unwritten — no published copy is created. (The body
  used to be a bare `{"error":"halted","reason":"<reason>"}` with no `code`
  or `request_id` — invisible to the bp CLI + SDK, which key on `error.code`;
  see fix(api): mutate halt returns the canonical error envelope.)

  End-to-end path exercised:

      MutateController.mutate/2
        → Content.apply_mutations/3
        → Content.publish_document/4
        → Barkpark.Plugins.Hooks.fire(:before_publish, payload)
        → {:halt, reason}
        → {:error, {:halted, reason}} (rolled back via Repo.rollback/1)
        → respond_with_error → Errors.to_envelope
        → HTTP 409 + {"error":{"code":"halted","message":reason,…}}

  `async: false` because the test mutates
  `Application.get_env(:barkpark, :plugins, …)` — global mutable state.
  `on_exit` restores the prior value so subsequent test files see the
  default plugin list.

  Inline plugin modules follow the bare-module pattern from
  `test/barkpark/plugins/hooks_test.exs` — `Barkpark.Plugins.Hooks` only
  requires `lifecycle_hooks/0` to be exported and return a map, so we
  skip `use Barkpark.Plugin` (which would require a `plugin.json` on
  disk).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  # ── Inline test plugins ────────────────────────────────────────────────

  defmodule HaltingPlugin do
    @moduledoc false
    def lifecycle_hooks do
      %{before_publish: [&__MODULE__.halt_publish/1]}
    end

    def halt_publish(_payload), do: {:halt, "test reason"}
  end

  defmodule PassthroughPlugin do
    @moduledoc false
    def lifecycle_hooks do
      %{before_publish: [&__MODULE__.ok/1]}
    end

    def ok(_payload), do: :ok
  end

  # ── Shared setup ───────────────────────────────────────────────────────

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "halt-path-integration",
      ["read", "write", "admin"]
    )

    {:ok, _schema} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "test"
      )

    # The tests below `put_env(:plugins, [SomePlugin])`; this restores the
    # snapshot. `PluginEnv.capture/0` (an `:unset` sentinel), not
    # `get_env(…, [])` — a `[]` default would restore an EXPLICIT `[]` on the
    # unset boot baseline, which is BootCollectors' discovery kill switch and
    # blanks plugin routes for every test that runs after this file.
    original = Barkpark.PluginEnv.capture()
    on_exit(fn -> Barkpark.PluginEnv.restore(original) end)

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  # Create a draft directly via Content so the test focuses on the
  # publish-halt path, not on create-side validation.
  defp create_draft!(doc_id) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"_id" => doc_id, "title" => "halt me"},
        "test"
      )

    doc
  end

  defp publish_body(doc_id) do
    Jason.encode!(%{
      "mutations" => [%{"publish" => %{"id" => doc_id, "type" => "post"}}]
    })
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "POST /v1/data/mutate/<dataset> publish — halt path" do
    test "returns HTTP 409 with halted body when before_publish hook halts", %{conn: conn} do
      _draft = create_draft!("halt-test-1")
      Application.put_env(:barkpark, :plugins, [HaltingPlugin])

      resp = conn |> authed() |> post("/v1/data/mutate/test", publish_body("halt-test-1"))

      assert resp.status == 409
      parsed = Jason.decode!(resp.resp_body)

      # CANONICAL envelope: a structured error object the bp CLI + SDK can decode
      # via error.code — NOT the old bare %{"error" => "halted", "reason" => …}.
      assert parsed["error"]["code"] == "halted"
      assert parsed["error"]["message"] == "test reason"
      assert is_binary(parsed["error"]["request_id"]) and parsed["error"]["request_id"] != ""
      # the old bare shape is gone: no top-level sibling "reason" key, and
      # error is an object rather than the string "halted"
      refute Map.has_key?(parsed, "reason")
      refute parsed["error"] == "halted"
    end

    test "passes through when before_publish returns :ok", %{conn: conn} do
      _draft = create_draft!("pass-test-1")
      Application.put_env(:barkpark, :plugins, [PassthroughPlugin])

      resp = conn |> authed() |> post("/v1/data/mutate/test", publish_body("pass-test-1"))

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert %{"transactionId" => _, "results" => [result]} = body
      assert result["operation"] == "publish"
      assert result["id"] == "pass-test-1"

      # Draft is gone, published exists.
      assert {:error, :not_found} = Content.get_document("drafts.pass-test-1", "post", "test")
      assert {:ok, %{status: "published"}} = Content.get_document("pass-test-1", "post", "test")
    end

    test "halt does not write — draft remains drafts.X after halted publish", %{conn: conn} do
      _draft = create_draft!("halt-noop-1")
      Application.put_env(:barkpark, :plugins, [HaltingPlugin])

      resp = conn |> authed() |> post("/v1/data/mutate/test", publish_body("halt-noop-1"))
      assert resp.status == 409

      # Draft must still be there; no published copy must exist.
      assert {:ok, %{doc_id: "drafts.halt-noop-1"}} =
               Content.get_document("drafts.halt-noop-1", "post", "test")

      assert {:error, :not_found} = Content.get_document("halt-noop-1", "post", "test")
    end
  end
end
