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

  defp run_plug(conn), do: PreviewTokenPlug.call(conn, PreviewTokenPlug.init([]))

  defp conn_for(jwt) do
    build_conn(:get, "/v1/data/doc/production/post/p1")
    |> put_req_header("authorization", "Preview " <> jwt)
  end

  test "valid JWT → 200, assigns claims, forces drafts perspective (first use)" do
    {jwt, _claims} = PreviewToken.sign(%{dataset: "production", doc_ids: ["p1"]}, secret())

    conn = run_plug(conn_for(jwt))

    refute conn.halted
    assert conn.assigns.preview_claims["dataset"] == "production"
    assert conn.assigns.forced_perspective == "drafts"
  end

  test "replay: second use of same token → 401 with reason \"replay\"" do
    {jwt, _claims} = PreviewToken.sign(%{dataset: "production"}, secret())

    first = run_plug(conn_for(jwt))
    refute first.halted

    second = run_plug(conn_for(jwt))
    assert second.halted
    assert second.status == 401

    body = Jason.decode!(second.resp_body)
    assert body["error"]["reason"] == "replay"
  end

  test "tampered JWT → 401 (signature rejected before replay check)" do
    {jwt, _claims} = PreviewToken.sign(%{dataset: "production"}, secret())

    [header, _payload, sig] = String.split(jwt, ".")
    bad_payload = Base.url_encode64(~s({"leak":true,"exp":99999999999}), padding: false)
    tampered = header <> "." <> bad_payload <> "." <> sig

    conn = run_plug(conn_for(tampered))

    assert conn.halted
    assert conn.status == 401
  end

  test "expired token rejected by expiry check before the replay check" do
    past = System.system_time(:second) - 100

    expired_claims = %{
      iss: "barkpark",
      iat: past - 1000,
      exp: past,
      dataset: "production",
      doc_ids: [],
      jti: Ecto.UUID.generate()
    }

    {jwt, _} = PreviewToken.sign(expired_claims, secret())

    conn = run_plug(conn_for(jwt))

    assert conn.halted
    assert conn.status == 401
    # Prove the plug short-circuited BEFORE record_jti — the JTI is still unknown,
    # so a fresh record_jti succeeds on first call.
    assert {:ok, _} = PreviewToken.record_jti(stringify(expired_claims))
  end

  test "revoked jti → 401" do
    {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, secret())
    string_claims = stringify(claims)
    {:ok, _} = PreviewToken.record_jti(string_claims)
    :ok = PreviewToken.revoke(string_claims["jti"])

    conn = run_plug(conn_for(jwt))

    assert conn.halted
    assert conn.status == 401
  end

  test "missing header → 401" do
    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> run_plug()

    assert conn.halted
    assert conn.status == 401
  end

  test "query param preview_token also works (first use)" do
    {jwt, _claims} = PreviewToken.sign(%{dataset: "production"}, secret())

    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1?preview_token=" <> jwt)
      |> Plug.Conn.fetch_query_params()
      |> run_plug()

    refute conn.halted
    assert conn.assigns.forced_perspective == "drafts"
  end

  test "concurrent requests with same JTI: exactly one succeeds, others get 401" do
    {jwt, _claims} = PreviewToken.sign(%{dataset: "production"}, secret())

    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, parent, self())
          run_plug(conn_for(jwt))
        end)
      end

    conns = Task.await_many(tasks, 5_000)

    successes = Enum.count(conns, fn c -> not c.halted end)
    failures = Enum.count(conns, fn c -> c.halted and c.status == 401 end)

    assert successes == 1,
           "expected exactly one concurrent request to succeed, got #{successes}"

    assert failures == length(conns) - 1
  end
end
