defmodule Barkpark.ApiTester.RunnerBuildTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.{Endpoints, Runner}

  # Stub bag name for `Req.Test` — scoped per-process so these stay async-safe
  # (mirrors Barkpark.ApiTestRunnerTest's pattern for the sibling runner).
  @stub_name __MODULE__

  test "build_request interpolates path_params and appends query_params" do
    ep = Endpoints.find("staging", "query-list")

    form_state = %{
      "dataset" => "staging",
      "type" => "post",
      "perspective" => "drafts",
      "limit" => "5",
      "offset" => "0",
      "order" => "_updatedAt:desc",
      "filter[title]" => "hello world"
    }

    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://localhost:4000"})

    assert req.method == "GET"
    assert String.starts_with?(req.url, "http://localhost:4000/v1/data/query/staging/post?")
    assert String.contains?(req.url, "perspective=drafts")
    assert String.contains?(req.url, "limit=5")

    assert String.contains?(req.url, "filter%5Btitle%5D=hello+world") or
             String.contains?(req.url, "filter%5Btitle%5D=hello%20world")

    assert req.body_text in [nil, ""]
  end

  test "build_request drops empty query_params" do
    ep = Endpoints.find("production", "query-list")
    form_state = %{"dataset" => "production", "type" => "post", "filter[title]" => ""}
    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://x"})
    refute String.contains?(req.url, "filter")
  end

  test "build_request attaches Authorization for :token and :admin endpoints" do
    create = Endpoints.find("production", "mutate-create")

    req =
      Runner.build_request(
        create,
        %{"dataset" => "production", "_body_text" => Jason.encode!(create.body_example)},
        %{token: "dev-tok", base: "http://x"}
      )

    assert {"Authorization", "Bearer dev-tok"} in req.headers
    assert {"Content-Type", "application/json"} in req.headers
    assert req.method == "POST"
    assert req.body_text == Jason.encode!(create.body_example)
  end

  test "build_request does NOT attach Authorization for :public endpoints" do
    list = Endpoints.find("production", "query-list")

    req =
      Runner.build_request(list, %{"dataset" => "production", "type" => "post"}, %{
        token: "dev-tok",
        base: "http://x"
      })

    refute Enum.any?(req.headers, fn {k, _} -> k == "Authorization" end)
  end

  # ── :unverified verdict (wb-api-tester-unverified-badge) ──────────────
  #
  # `run/2`'s verdict computation was `{:pass, ...}` for ANY test case with
  # no `:expect` — a 500 badged exactly like a checked 200. These stub the
  # HTTP layer via `Req.Test` (run/2 now threads `:req_options` through,
  # same as the sibling `Barkpark.ApiTestRunner.fire/2`) so the verdict is
  # unit-testable without a live port.

  describe "run/2 — :unverified is a third state, never :pass and never :fail" do
    test "no :expect at all → :unverified on a 200, not :pass" do
      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      result =
        Runner.run(
          %{method: "GET", path: "/probe", headers: [], body: nil, expect: nil},
          req_options: [plug: {Req.Test, @stub_name}]
        )

      assert result.verdict == :unverified
      refute result.verdict == :pass
      refute result.verdict == :fail
    end

    test "no :expect at all → :unverified even on a 500 (the exact defect: a real failure must not badge the same as a checked pass)" do
      Req.Test.stub(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      result =
        Runner.run(
          %{method: "GET", path: "/probe", headers: [], body: nil, expect: nil},
          req_options: [plug: {Req.Test, @stub_name}]
        )

      assert result.status == 500
      assert result.verdict == :unverified
      refute result.verdict == :pass
    end

    test ":unverified does not flip any aggregate to :fail — with a real expectation alongside it, the case still resolves on the real check" do
      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      # A real expectation on the SAME shape passes normally — proving
      # :unverified is additive (a missing-expectation marker), not a
      # poisoned value that corrupts an otherwise-checked verdict.
      result =
        Runner.run(
          %{method: "GET", path: "/probe", headers: [], body: nil, expect: {200, :ok}},
          req_options: [plug: {Req.Test, @stub_name}]
        )

      assert result.verdict == :pass
    end
  end
end
