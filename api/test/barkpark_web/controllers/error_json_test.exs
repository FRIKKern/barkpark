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
    # Generic builder text only — never an exception message / stack.
    assert env.message == "unknown error"
    refute Map.has_key?(env, :status)
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
