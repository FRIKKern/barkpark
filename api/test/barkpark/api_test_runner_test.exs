defmodule Barkpark.ApiTestRunnerTest do
  @moduledoc """
  Round-trip coverage for `Barkpark.ApiTestRunner.run/2` and
  `run_one/3` (plan §0 Q1, Q3, Q5, Q6, Q8 — Goal `barkpark-bsp`).

  Uses `Req.Test` to stub HTTP responses in-process — the runner
  threads its `:req_options` opt directly into `Req.request/1`, so we
  pass `plug: {Req.Test, __MODULE__}` and register a stub plug per
  test. No live network, no Bandit boot — the entire round-trip is
  pure-process.

  Covers four behavioural slices:

    * happy-path pass (asserts + duration + redacted request)
    * failing assert → `status: :fail`
    * connection error → `status: :error` (request never lands)
    * cleanup steps fire ALWAYS after asserts (plan Q1) — even on
      :fail — and are visible in the result map's `:cleanup` list.

  Async-safe because every stub call binds to the calling process via
  `Req.Test`'s ownership server.
  """

  use ExUnit.Case, async: true

  alias Barkpark.ApiTestRunner

  # Stub bag name — `Req.Test.stub/2` keys responses against this. Every
  # test runs in its own process; `Req.Test`'s ownership server scopes
  # the stub to the caller.
  @stub_name __MODULE__

  defp req_options, do: [plug: {Req.Test, @stub_name}]

  defp run_one_with_stub(spec, stub_fn, extra_opts \\ []) do
    Req.Test.stub(@stub_name, stub_fn)
    opts = Keyword.merge([req_options: req_options()], extra_opts)
    ApiTestRunner.run_one(spec, "http://stub.local", opts)
  end

  # ─── happy-path ─────────────────────────────────────────────────────

  describe "run_one/3 — happy path" do
    test "returns :pass when every assert evaluates to :pass" do
      spec = %{
        name: "happy",
        method: :get,
        path: "/echo",
        auth: :none,
        asserts: [
          {:status, 200},
          {:body_contains, ~s|"ok":true|}
        ]
      }

      result =
        run_one_with_stub(spec, fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/echo"
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert result.status == :pass
      assert result.name == "happy"
      assert is_integer(result.duration_ms)
      assert result.response.status == 200
      assert result.response.body =~ ~s|"ok":true|

      # All asserts recorded with their pass/fail kind and message.
      assert length(result.asserts) == 2
      assert Enum.all?(result.asserts, fn {_tag, kind, _msg} -> kind == :pass end)

      # Cleanup list is empty when the spec has no :cleanup steps.
      assert result.cleanup == []
    end

    test "auth: :admin redacts the bearer token from the result's :request" do
      spec = %{
        name: "redact",
        method: :get,
        path: "/whoami",
        auth: :admin,
        asserts: [{:status, 200}]
      }

      result =
        run_one_with_stub(spec, fn conn ->
          # The runner DID send the real token over the wire — only the
          # returned result map redacts.
          auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
          assert is_binary(auth)
          assert String.starts_with?(auth, "Bearer ")
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert result.status == :pass
      assert result.request.headers["authorization"] == "[redacted]"
    end
  end

  # ─── failing assert ─────────────────────────────────────────────────

  describe "run_one/3 — failing assert" do
    test "returns :fail when an assert evaluates to :fail" do
      spec = %{
        name: "wrong-status",
        method: :get,
        path: "/teapot",
        auth: :none,
        asserts: [{:status, 200}]
      }

      result =
        run_one_with_stub(spec, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(418, "nope")
        end)

      assert result.status == :fail
      assert result.response.status == 418
      assert [{_tag, :fail, msg}] = result.asserts
      assert msg =~ "418"
    end
  end

  # ─── connection error ───────────────────────────────────────────────

  describe "run_one/3 — connection error" do
    test "returns :error when the request never produces a response" do
      spec = %{
        name: "boom",
        method: :get,
        path: "/never",
        auth: :none,
        asserts: [{:status, 200}]
      }

      # Req.Test.transport_error/2 simulates a low-level transport
      # failure — Req returns {:error, _} and the runner records
      # :error with the request's error message.
      result =
        run_one_with_stub(spec, fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end)

      assert result.status == :error
      assert is_nil(result.response)
      assert [{:request, :error, msg}] = result.asserts
      assert is_binary(msg)
    end
  end

  # ─── cleanup fires always (plan Q1) ─────────────────────────────────

  describe "run_one/3 — cleanup" do
    test "cleanup steps fire after asserts even when asserts FAIL" do
      # Spec FAILS its assert (we'll return 500, expect 200), but the
      # cleanup step still must fire. We register a stub that handles
      # BOTH the primary GET and the cleanup DELETE — count the calls
      # via the test process inbox.
      parent = self()

      stub_fn = fn conn ->
        send(parent, {:hit, conn.method, conn.request_path})

        case {conn.method, conn.request_path} do
          {"GET", "/will-fail"} ->
            Plug.Conn.send_resp(conn, 500, "boom")

          {"DELETE", "/cleanup"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      spec = %{
        name: "cleanup-on-fail",
        method: :get,
        path: "/will-fail",
        auth: :none,
        asserts: [{:status, 200}],
        cleanup: [%{method: :delete, path: "/cleanup", auth: :none}]
      }

      result = run_one_with_stub(spec, stub_fn)

      # Both requests landed at the stub plug — assertion proves the
      # cleanup ran even though the primary assert failed.
      assert_received {:hit, "GET", "/will-fail"}
      assert_received {:hit, "DELETE", "/cleanup"}

      assert result.status == :fail
      assert [%{method: :delete, path: "/cleanup", status: 204}] = result.cleanup
    end
  end

  # ─── run/2 batch ────────────────────────────────────────────────────

  describe "run/2 — batch" do
    test "returns one result per spec in input order" do
      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/a" -> Req.Test.json(conn, %{"a" => 1})
          "/b" -> Req.Test.json(conn, %{"b" => 2})
        end
      end)

      specs = [
        %{name: "a", method: :get, path: "/a", auth: :none, asserts: [{:status, 200}]},
        %{name: "b", method: :get, path: "/b", auth: :none, asserts: [{:status, 200}]}
      ]

      results =
        ApiTestRunner.run(specs,
          base_url: "http://stub.local",
          req_options: req_options()
        )

      assert [%{name: "a", status: :pass}, %{name: "b", status: :pass}] = results
    end
  end
end
