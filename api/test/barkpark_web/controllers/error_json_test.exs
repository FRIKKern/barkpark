defmodule BarkparkWeb.ErrorJSONTest do
  use BarkparkWeb.ConnCase, async: true

  # The crash-path renderer must emit the SAME canonical v1 envelope as
  # BarkparkWeb.FallbackController (`%{error: %{code, message, ...}}`), built by
  # Barkpark.Content.Errors — NOT the Phoenix default `%{errors: %{detail: ...}}`
  # — so SDK/CLI consumers can key on `error.code` on a 500 exactly as they do on
  # a controller-emitted error.

  test "renders 404 as the canonical not_found envelope" do
    assert %{error: env} = BarkparkWeb.ErrorJSON.render("404.json", %{})
    assert env.code == "not_found"
    assert env.message == "document not found"
    # No :status inside the body — it lives on the HTTP response, matching the
    # FallbackController wrapping (Map.delete(env, :status)).
    refute Map.has_key?(env, :status)
  end

  test "renders 500 as a generic internal_error envelope with NO leaked detail" do
    assert %{error: env} = BarkparkWeb.ErrorJSON.render("500.json", %{})
    assert env.code == "internal_error"
    # No fault in scope at all (empty assigns) — the generic builder text, with
    # no family suffix invented.
    assert env.message == "unknown error"
    refute Map.has_key?(env, :status)
  end

  # ── The fault FAMILY (the message), with the code held byte-identical ──────
  #
  # An operator reading a deploy log has to be able to tell a pool blip from a
  # code defect. The family is the smallest disclosure that does that; the
  # exception's own message, the inspected reason and the stack stay out.

  test "names the exception module as the family for a raised error" do
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :error,
               reason: %RuntimeError{message: "boom — secret detail"},
               stack: []
             })

    assert env.code == "internal_error"
    assert env.message == "unknown error (RuntimeError)"
    refute env.message =~ "boom"
    refute env.message =~ "secret"
  end

  test "names a nested exception module in full" do
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :error,
               reason: %Ecto.Query.CastError{message: "cannot cast \"s3cret\" to :binary_id"},
               stack: []
             })

    assert env.code == "internal_error"
    assert env.message == "unknown error (Ecto.Query.CastError)"
    refute env.message =~ "s3cret"
  end

  # ── A refused or lost DB connection is TYPED (task-f8233616de3513d4) ──────
  #
  # Under pool shedding it raises from plugs before any controller runs, and
  # used to answer `internal_error`. It is the transient 503 the controller
  # arms already give: `storage_unavailable` / `connection_unavailable`.

  defp conn_fault(method) do
    BarkparkWeb.ErrorJSON.render("503.json", %{
      kind: :error,
      reason:
        DBConnection.ConnectionError.exception(
          "connection not available and request was dropped from queue after 50ms s3cret",
          :queue_timeout
        ),
      stack: [],
      conn: Plug.Test.conn(method, "/v1/data/mutate/production")
    })
  end

  test "a DB connection fault on a WRITE answers storage_unavailable with the write hint" do
    assert %{error: env} = conn_fault(:post)
    assert env.code == "storage_unavailable"
    assert env.reason == "connection_unavailable"
    assert env.hint =~ "CHECK WHETHER IT LANDED"
    assert env.message == "the database connection was refused or lost while serving this request"
    refute env.message =~ "s3cret"
    refute env.message =~ "queue"
  end

  test "a DB connection fault on a READ answers storage_unavailable with the read hint" do
    assert %{error: env} = conn_fault(:get)
    assert env.code == "storage_unavailable"
    assert env.reason == "connection_unavailable"
    assert env.hint =~ "CHANGED nothing"
  end

  test "a DB connection fault with no conn in scope still types (the write hint, the safe one)" do
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("503.json", %{
               kind: :error,
               reason: DBConnection.ConnectionError.exception("dropped", :queue_timeout),
               stack: []
             })

    assert env.code == "storage_unavailable"
    assert env.hint =~ "CHECK WHETHER IT LANDED"
  end

  # CONTROL: only the SHED is typed. A lost connection that is not a queue drop
  # keeps HTTP 500 (`BarkparkWeb.PoolOverload.status/1`), so its body keeps the
  # 500 code — a typed 503 code on a 500 would be one code at two statuses.
  test "CONTROL — a non-shed connection fault (HTTP 500) keeps internal_error" do
    error = DBConnection.ConnectionError.exception("tcp recv: closed")
    assert BarkparkWeb.PoolOverload.status(error) == 500

    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :error,
               reason: error,
               stack: [],
               conn: Plug.Test.conn(:post, "/v1/data/mutate/production")
             })

    assert env.code == "internal_error"
    assert env.message == "unknown error (DBConnection.ConnectionError)"
    refute env.message =~ "tcp"
  end

  test "an EXIT from the pool is not typed: only the raised ConnectionError is" do
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :exit,
               reason: {:timeout, {DBConnection.Holder, :checkout, []}},
               stack: []
             })

    assert env.code == "internal_error"
  end

  test "speaks an allowlisted exit head atom and never its payload" do
    # `:exit` hands over a BARE TERM (no Exception.normalize), and the payload
    # carries the GenServer.call argument list — caller data.
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :exit,
               reason: {:timeout, {GenServer, :call, [:some_pool, {:checkout, "s3cret"}, 5000]}},
               stack: []
             })

    assert env.code == "internal_error"
    assert env.message == "unknown error (exit: timeout)"
    refute env.message =~ "s3cret"
    refute env.message =~ "GenServer"
  end

  test "degrades an unlisted exit reason to the bare word exit" do
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :exit,
               reason: {:bad_return_value, %{token: "s3cret"}},
               stack: []
             })

    assert env.message == "unknown error (exit)"
    refute env.message =~ "s3cret"
    refute env.message =~ "bad_return_value"
  end

  test "a thrown bare term yields no family at all" do
    # A throw is arbitrary caller data end to end — there is no safe constant to
    # name, and reading a struct field off it would raise inside the renderer.
    assert %{error: env} =
             BarkparkWeb.ErrorJSON.render("500.json", %{
               kind: :throw,
               reason: {:secret_token, "s3cret"},
               stack: []
             })

    assert env.code == "internal_error"
    assert env.message == "unknown error"
  end

  test "the code stays byte-identical internal_error across every fault kind" do
    # The cloud deploy poller grants its retry grace on the CODE, never the
    # message (BarkparkCloud.Sites.Deploy.transient_refusal?/1). Moving the code
    # would turn that grace terminal — so the message is the ONLY thing that
    # varies here.
    faults = [
      %{},
      %{kind: :error, reason: %RuntimeError{message: "boom"}, stack: []},
      %{kind: :exit, reason: {:timeout, {GenServer, :call, []}}, stack: []},
      %{kind: :exit, reason: :killed, stack: []},
      %{kind: :throw, reason: :nope, stack: []}
    ]

    for assigns <- faults do
      assert %{error: %{code: code}} = BarkparkWeb.ErrorJSON.render("500.json", assigns)
      assert code == "internal_error"
    end
  end

  test "catch-all template collapses any other status to internal_error" do
    assert %{error: %{code: "internal_error"}} =
             BarkparkWeb.ErrorJSON.render("503.json", %{})
  end

  test "passes the conn through so request_id can be attached" do
    # With a live conn carrying an x-request-id, the envelope surfaces it — the
    # same field FallbackController emits for correlation.
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_resp_header("x-request-id", "req-abc123")
    assert %{error: env} = BarkparkWeb.ErrorJSON.render("500.json", %{conn: conn})
    assert env.request_id == "req-abc123"
  end
end
