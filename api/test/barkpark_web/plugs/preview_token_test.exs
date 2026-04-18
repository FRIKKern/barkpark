defmodule BarkparkWeb.Plugs.PreviewTokenTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.PreviewToken
  alias BarkparkWeb.Plugs.PreviewToken, as: PreviewTokenPlug

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: "test-preview-secret-abcdefghijklmnop",
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    :ok
  end

  defp secret, do: Application.get_env(:barkpark, :preview)[:secret]

  defp stringify(claims), do: Map.new(claims, fn {k, v} -> {to_string(k), v} end)

  test "valid JWT in Authorization header assigns claims and forces drafts perspective" do
    {jwt, claims} = PreviewToken.sign(%{dataset: "production", doc_ids: ["p1"]}, secret())
    :ok = PreviewToken.record_jti(stringify(claims))

    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> put_req_header("authorization", "Preview " <> jwt)
      |> PreviewTokenPlug.call(PreviewTokenPlug.init([]))

    refute conn.halted
    assert conn.assigns.preview_claims["dataset"] == "production"
    assert conn.assigns.forced_perspective == "drafts"
  end

  test "tampered JWT → 401" do
    {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, secret())
    :ok = PreviewToken.record_jti(stringify(claims))

    [header, _payload, sig] = String.split(jwt, ".")
    bad_payload = Base.url_encode64(~s({"leak":true,"exp":99999999999}), padding: false)
    tampered = header <> "." <> bad_payload <> "." <> sig

    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> put_req_header("authorization", "Preview " <> tampered)
      |> PreviewTokenPlug.call(PreviewTokenPlug.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "revoked jti → 401" do
    {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, secret())
    string_claims = stringify(claims)
    :ok = PreviewToken.record_jti(string_claims)
    :ok = PreviewToken.revoke(string_claims["jti"])

    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> put_req_header("authorization", "Preview " <> jwt)
      |> PreviewTokenPlug.call(PreviewTokenPlug.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "missing header → 401" do
    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> PreviewTokenPlug.call(PreviewTokenPlug.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "query param preview_token also works" do
    {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, secret())
    :ok = PreviewToken.record_jti(stringify(claims))

    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1?preview_token=" <> jwt)
      |> Plug.Conn.fetch_query_params()
      |> PreviewTokenPlug.call(PreviewTokenPlug.init([]))

    refute conn.halted
    assert conn.assigns.forced_perspective == "drafts"
  end
end
