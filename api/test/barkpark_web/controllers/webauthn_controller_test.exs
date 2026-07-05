defmodule BarkparkWeb.WebauthnControllerTest do
  @moduledoc """
  Passkey (WebAuthn) HTTP surface. A software authenticator (ES256 / P-256)
  produces real attestation objects and assertions in-process, so the full
  ceremony is verified end-to-end through `wax` WITHOUT a browser — only the
  actual `navigator.credentials` call is browser-gated.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  alias Barkpark.{Accounts, Audit, Repo}
  alias Barkpark.Audit.Event
  alias Barkpark.Accounts.Webauthn

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}") |> json_conn()

  setup %{conn: conn} do
    conn |> json_conn() |> post("/v1/auth/register", Jason.encode!(%{email: "pk@example.com", password: @password}))
    token =
      build_conn() |> json_conn()
      |> post("/v1/auth/login", Jason.encode!(%{email: "pk@example.com", password: @password}))
      |> json_response(201)
      |> Map.fetch!("token")

    %{token: token, user: Accounts.get_user_by_email("pk@example.com")}
  end

  # ── software authenticator (ES256 / P-256, "none" attestation) ───────────────

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # Build an attestation response for a registration `challenge_b64`. Returns the
  # POST body plus the authenticator's private key + credential id for reuse.
  defp make_credential(challenge_b64) do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    <<4, x::binary-32, y::binary-32>> = pub

    cose =
      CBOR.encode(%{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: x},
        -3 => %CBOR.Tag{tag: :bytes, value: y}
      })

    cred_id = :crypto.strong_rand_bytes(16)
    acd = <<0::128>> <> <<byte_size(cred_id)::16>> <> cred_id <> cose
    # rpIdHash || flags(UP|UV|AT = 0x45) || signCount(0) || attestedCredentialData
    auth_data = :crypto.hash(:sha256, Webauthn.rp_id()) <> <<0x45>> <> <<0::32>> <> acd

    att_obj = CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}})
    cdj = client_data("webauthn.create", challenge_b64)

    %{
      body: %{attestation_object: b64(att_obj), client_data_json: b64(cdj)},
      priv: priv,
      cred_id: cred_id
    }
  end

  # Build an assertion for `challenge_b64` from a previously-made credential.
  defp make_assertion(cred, challenge_b64, sign_count) do
    auth_data = :crypto.hash(:sha256, Webauthn.rp_id()) <> <<0x05>> <> <<sign_count::32>>
    cdj = client_data("webauthn.get", challenge_b64)
    msg = auth_data <> :crypto.hash(:sha256, cdj)
    sig = :crypto.sign(:ecdsa, :sha256, msg, [cred.priv, :prime256v1])

    %{
      credential_id: b64(cred.cred_id),
      authenticator_data: b64(auth_data),
      signature: b64(sig),
      client_data_json: b64(cdj)
    }
  end

  defp client_data(type, challenge_b64),
    do: Jason.encode!(%{type: type, challenge: challenge_b64, origin: Webauthn.origin()})

  # Register a passkey via the real endpoints; returns the credential handle.
  defp register!(token) do
    ch = authed(token) |> post("/v1/auth/webauthn/register/challenge", "{}") |> json_response(200)
    cred = make_credential(ch["challenge"])

    authed(token)
    |> post("/v1/auth/webauthn/register", Jason.encode!(Map.put(cred.body, :challenge_token, ch["challenge_token"])))
    |> json_response(201)

    cred
  end

  # ── tests ────────────────────────────────────────────────────────────────────

  test "register a passkey, then sign in with it (usernameless) → a fresh session", %{token: token, user: user} do
    cred = register!(token)
    assert Webauthn.has_passkey?(user)

    # Usernameless login: challenge → assertion → session token.
    ch = build_conn() |> json_conn() |> post("/v1/auth/webauthn/login/challenge", "{}") |> json_response(200)
    assertion = make_assertion(cred, ch["challenge"], 1)

    resp =
      build_conn() |> json_conn()
      |> post("/v1/auth/webauthn/login", Jason.encode!(Map.put(assertion, :challenge_token, ch["challenge_token"])))
      |> json_response(201)

    assert resp["token"]
    assert resp["user"]["email"] == "pk@example.com"
  end

  test "a forged/mismatched assertion is rejected", %{token: token} do
    _cred = register!(token)
    # A DIFFERENT authenticator (wrong key) for the same cred id-less challenge.
    ch = build_conn() |> json_conn() |> post("/v1/auth/webauthn/login/challenge", "{}") |> json_response(200)
    forged = make_credential(ch["challenge"])
    bogus = make_assertion(%{priv: forged.priv, cred_id: :crypto.strong_rand_bytes(16)}, ch["challenge"], 1)

    assert build_conn() |> json_conn()
           |> post("/v1/auth/webauthn/login", Jason.encode!(Map.put(bogus, :challenge_token, ch["challenge_token"])))
           |> json_response(401)
  end

  test "a passkey clears a step-up challenge (factor-agnostic gate)", %{token: token, user: user} do
    cred = register!(token)
    # A passkey counts as an MFA factor, so the user is now gated on sensitive actions.
    assert Accounts.mfa_enrolled?(user)

    # Age the session so a guarded action (mfa/disable) is challenged.
    hash = Accounts.UserSession.hash_token(token)
    old = DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:microsecond)
    Repo.update_all(from(s in Accounts.UserSession, where: s.token_hash == ^hash), set: [mfa_verified_at: old])

    assert authed(token) |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password})) |> json_response(401)

    # Step up with the passkey → fresh again.
    ch = authed(token) |> post("/v1/auth/webauthn/step-up/challenge", "{}") |> json_response(200)
    assertion = make_assertion(cred, ch["challenge"], 1)

    step =
      authed(token)
      |> post("/v1/auth/webauthn/step-up", Jason.encode!(Map.put(assertion, :challenge_token, ch["challenge_token"])))
      |> json_response(200)

    assert step["factor"] == "passkey"
  end

  test "a replayed assertion (non-increasing sign count) is rejected as a clone", %{token: token} do
    cred = register!(token)

    first = fn count ->
      ch = build_conn() |> json_conn() |> post("/v1/auth/webauthn/login/challenge", "{}") |> json_response(200)
      build_conn() |> json_conn()
      |> post("/v1/auth/webauthn/login", Jason.encode!(Map.put(make_assertion(cred, ch["challenge"], count), :challenge_token, ch["challenge_token"])))
    end

    assert first.(5) |> json_response(201)
    # A later assertion with a LOWER counter than the stored 5 → clone signal.
    assert first.(3) |> json_response(401)
  end

  test "list and delete passkeys; registration + login emit audit", %{token: token} do
    cred = register!(token)
    assert Repo.one(from e in Event, where: e.action == "passkey_registered")

    list = authed(token) |> get("/v1/auth/webauthn/credentials") |> json_response(200)
    assert [%{"id" => id}] = list["credentials"]

    # login emits passkey_login
    ch = build_conn() |> json_conn() |> post("/v1/auth/webauthn/login/challenge", "{}") |> json_response(200)
    build_conn() |> json_conn()
    |> post("/v1/auth/webauthn/login", Jason.encode!(Map.put(make_assertion(cred, ch["challenge"], 1), :challenge_token, ch["challenge_token"])))
    |> json_response(201)

    assert Repo.one(from e in Event, where: e.action == "passkey_login")
    assert :ok == Audit.verify_chain(nil)

    # delete removes it
    assert authed(token) |> delete("/v1/auth/webauthn/credentials/#{id}") |> json_response(200)
    assert authed(token) |> get("/v1/auth/webauthn/credentials") |> json_response(200) |> Map.fetch!("credentials") == []
  end
end
