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

  defp authed(token),
    do: scoped_conn() |> put_req_header("authorization", "Bearer #{token}") |> json_conn()

  setup %{conn: conn} do
    conn
    |> json_conn()
    |> post("/v1/auth/register", Jason.encode!(%{email: "pk@example.com", password: @password}))

    token =
      scoped_conn()
      |> json_conn()
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

    att_obj =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

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
    |> post(
      "/v1/auth/webauthn/register",
      Jason.encode!(Map.put(cred.body, :challenge_token, ch["challenge_token"]))
    )
    |> json_response(201)

    cred
  end

  # ── tests ────────────────────────────────────────────────────────────────────

  test "register a passkey, then sign in with it (usernameless) → a fresh session", %{
    token: token,
    user: user
  } do
    cred = register!(token)
    assert Webauthn.has_passkey?(user)

    # Usernameless login: challenge → assertion → session token.
    ch =
      scoped_conn()
      |> json_conn()
      |> post("/v1/auth/webauthn/login/challenge", "{}")
      |> json_response(200)

    assertion = make_assertion(cred, ch["challenge"], 1)

    resp =
      scoped_conn()
      |> json_conn()
      |> post(
        "/v1/auth/webauthn/login",
        Jason.encode!(Map.put(assertion, :challenge_token, ch["challenge_token"]))
      )
      |> json_response(201)

    assert resp["token"]
    assert resp["user"]["email"] == "pk@example.com"
  end

  test "a forged/mismatched assertion is rejected", %{token: token} do
    _cred = register!(token)
    # A DIFFERENT authenticator (wrong key) for the same cred id-less challenge.
    ch =
      scoped_conn()
      |> json_conn()
      |> post("/v1/auth/webauthn/login/challenge", "{}")
      |> json_response(200)

    forged = make_credential(ch["challenge"])

    bogus =
      make_assertion(
        %{priv: forged.priv, cred_id: :crypto.strong_rand_bytes(16)},
        ch["challenge"],
        1
      )

    assert scoped_conn()
           |> json_conn()
           |> post(
             "/v1/auth/webauthn/login",
             Jason.encode!(Map.put(bogus, :challenge_token, ch["challenge_token"]))
           )
           |> json_response(401)
  end

  test "a passkey clears a step-up challenge (factor-agnostic gate)", %{token: token, user: user} do
    cred = register!(token)
    # A passkey counts as an MFA factor, so the user is now gated on sensitive actions.
    assert Accounts.mfa_enrolled?(user)

    # Age the session so a guarded action (mfa/disable) is challenged.
    hash = Accounts.UserSession.hash_token(token)
    old = DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:microsecond)

    Repo.update_all(from(s in Accounts.UserSession, where: s.token_hash == ^hash),
      set: [mfa_verified_at: old]
    )

    assert authed(token)
           |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
           |> json_response(401)

    # Step up with the passkey → fresh again.
    ch = authed(token) |> post("/v1/auth/webauthn/step-up/challenge", "{}") |> json_response(200)
    assertion = make_assertion(cred, ch["challenge"], 1)

    step =
      authed(token)
      |> post(
        "/v1/auth/webauthn/step-up",
        Jason.encode!(Map.put(assertion, :challenge_token, ch["challenge_token"]))
      )
      |> json_response(200)

    assert step["factor"] == "passkey"
  end

  test "a replayed assertion (non-increasing sign count) is rejected as a clone", %{token: token} do
    cred = register!(token)

    first = fn count ->
      ch =
        scoped_conn()
        |> json_conn()
        |> post("/v1/auth/webauthn/login/challenge", "{}")
        |> json_response(200)

      scoped_conn()
      |> json_conn()
      |> post(
        "/v1/auth/webauthn/login",
        Jason.encode!(
          Map.put(
            make_assertion(cred, ch["challenge"], count),
            :challenge_token,
            ch["challenge_token"]
          )
        )
      )
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
    ch =
      scoped_conn()
      |> json_conn()
      |> post("/v1/auth/webauthn/login/challenge", "{}")
      |> json_response(200)

    scoped_conn()
    |> json_conn()
    |> post(
      "/v1/auth/webauthn/login",
      Jason.encode!(
        Map.put(make_assertion(cred, ch["challenge"], 1), :challenge_token, ch["challenge_token"])
      )
    )
    |> json_response(201)

    assert Repo.one(from e in Event, where: e.action == "passkey_login")
    assert :ok == Audit.verify_chain(nil)

    # delete removes it — DIRECT Repo readback, not the list endpoint: a bug
    # present in both delete and list would sail through an HTTP-list check
    # (pds-bl-w36-groupc-remainder criterion 1).
    assert authed(token) |> delete("/v1/auth/webauthn/credentials/#{id}") |> json_response(200)
    assert Repo.get(Barkpark.Accounts.WebauthnCredential, id) == nil
  end

  # BinToTerm scar: the stored `cose_key` is decoded with `binary_to_term/2
  # [:safe]`. A poisoned column (backup restore / injection) carrying a
  # well-formed term with a novel atom must fail authentication CLOSED and never
  # mint the atom (atom-table exhaustion), instead of materializing it.
  test "a poisoned cose_key fails closed without minting an atom (:safe decode)", %{token: token} do
    cred = register!(token)

    novel = "webauthn_cose_novel_atom_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end

    # <<131>> magic + SMALL_ATOM_UTF8_EXT (119) for a not-yet-interned atom.
    crafted = <<131, 119, byte_size(novel)::8, novel::binary>>

    {1, _} =
      Repo.update_all(
        from(c in Accounts.WebauthnCredential, where: c.credential_id == ^cred.cred_id),
        set: [cose_key: crafted]
      )

    # load_cose runs before Wax.authenticate, so the crafted key is what's
    # exercised: [:safe] rejects it → fail-closed error, not a materialized atom.
    assert {:error, :corrupt_credential} =
             Webauthn.verify_authentication(cred.cred_id, <<>>, <<>>, "{}", <<0::256>>)

    assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
  end

  # Binary_id scar: a non-UUID :id must fold into not_found, NOT raise
  # Ecto.CastError → 500 inside the id: get_by cast. Any authed user could
  # trigger the 500 trivially by DELETEing a garbage id.
  test "DELETE a non-UUID credential id → 404 not_found, never a CastError 500", %{
    token: token,
    user: user
  } do
    assert authed(token)
           |> delete("/v1/auth/webauthn/credentials/not-a-uuid")
           |> json_response(404)

    # context guard short-circuits before any Postgres cast
    assert {:error, :not_found} == Webauthn.delete_credential(user, "not-a-uuid")
  end

  # ── direct-Repo readback differentials (pds-bl-w36-groupc-remainder) ──────
  #
  # PDS-D501 ruling: these land HERE, beside the file's own ES256/P-256
  # software authenticator — never a duplicated harness elsewhere. The prior
  # Repo reads in this file were audit-Event EXISTENCE assertions
  # (side-effect-existence-only); each test below reads the ROW the verb's
  # receipt is about, directly, and ties it to the response byte-for-byte.
  describe "direct-Repo readback differentials" do
    alias Barkpark.Accounts.WebauthnCredential

    test "register (201 receipt) is backed by the STORED credential row", %{
      token: token,
      user: user
    } do
      ch =
        authed(token) |> post("/v1/auth/webauthn/register/challenge", "{}") |> json_response(200)

      cred = make_credential(ch["challenge"])

      resp =
        authed(token)
        |> post(
          "/v1/auth/webauthn/register",
          Jason.encode!(Map.put(cred.body, :challenge_token, ch["challenge_token"]))
        )
        |> json_response(201)

      # The receipt's credential id names a REAL stored row, owned by the
      # registering user, carrying the key material a later login needs.
      assert %WebauthnCredential{} = row = Repo.get(WebauthnCredential, resp["credential"]["id"])
      assert row.user_id == user.id
      assert is_binary(row.cose_key) and byte_size(row.cose_key) > 0
      assert row.sign_count == 0
    end

    test "step-up (200 receipt) is backed by the STORED session mfa_verified_at — " <>
           "fresh_until derives from the row, not from prose",
         %{token: token, user: user} do
      cred = register!(token)
      assert Accounts.mfa_enrolled?(user)

      hash = Accounts.UserSession.hash_token(token)

      old =
        DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:microsecond)

      Repo.update_all(from(s in Accounts.UserSession, where: s.token_hash == ^hash),
        set: [mfa_verified_at: old]
      )

      ch =
        authed(token) |> post("/v1/auth/webauthn/step-up/challenge", "{}") |> json_response(200)

      assertion = make_assertion(cred, ch["challenge"], 1)

      step =
        authed(token)
        |> post(
          "/v1/auth/webauthn/step-up",
          Jason.encode!(Map.put(assertion, :challenge_token, ch["challenge_token"]))
        )
        |> json_response(200)

      # DIRECT row read: the stamp actually landed (not the aged value)…
      stored =
        Repo.one(from s in Accounts.UserSession, where: s.token_hash == ^hash)

      assert DateTime.compare(stored.mfa_verified_at, old) == :gt

      # …and the receipt's fresh_until is DERIVED from the stored stamp.
      expected =
        DateTime.add(
          stored.mfa_verified_at,
          Accounts.UserSession.default_step_up_window(),
          :second
        )

      assert {:ok, fresh_until, _} = DateTime.from_iso8601(step["fresh_until"])
      assert DateTime.compare(fresh_until, expected) == :eq
    end

    test "delete is USER-SCOPED and the claim is ROW ABSENCE: a foreign user's DELETE " <>
           "404s and the row survives; the owner's DELETE removes the row",
         %{token: token} do
      cred_id =
        register!(token)
        |> then(fn _ ->
          [%{"id" => id}] =
            authed(token)
            |> get("/v1/auth/webauthn/credentials")
            |> json_response(200)
            |> Map.fetch!("credentials")

          id
        end)

      # A SECOND authenticated user attacks the first user's credential id.
      scoped_conn()
      |> json_conn()
      |> post(
        "/v1/auth/register",
        Jason.encode!(%{email: "intruder@example.com", password: @password})
      )

      other_token =
        scoped_conn()
        |> json_conn()
        |> post(
          "/v1/auth/login",
          Jason.encode!(%{email: "intruder@example.com", password: @password})
        )
        |> json_response(201)
        |> Map.fetch!("token")

      assert authed(other_token)
             |> delete("/v1/auth/webauthn/credentials/#{cred_id}")
             |> json_response(404)

      # The row SURVIVED the cross-user attempt — direct read, not a list.
      assert %WebauthnCredential{} = Repo.get(WebauthnCredential, cred_id)

      # The owner's delete removes it — the receipt's claim is the ABSENCE.
      assert authed(token)
             |> delete("/v1/auth/webauthn/credentials/#{cred_id}")
             |> json_response(200)

      assert Repo.get(WebauthnCredential, cred_id) == nil
    end

    # RECEIPT LAW (pds wave 39 residue). The test above pins the ABSENCE the
    # verb causes; this one pins that the printed sentence DESCENDS FROM THE
    # WRITE RETURN. `Webauthn.delete_credential/2` was widened from a bare `:ok`
    # to `{:ok, row}` so the controller has a row to render at all.
    test "delete (200 receipt) renders the ROW Repo.delete removed — nickname and " <>
           "created_at are store fields the request never carried",
         %{token: token} do
      register!(token)

      [%{"id" => cred_id}] =
        authed(token)
        |> get("/v1/auth/webauthn/credentials")
        |> json_response(200)
        |> Map.fetch!("credentials")

      # Read the row that is ABOUT to be deleted, directly — these are the bytes
      # the receipt has to reproduce, and none of them ride the DELETE request,
      # which carries the id and nothing else.
      before = Repo.get(WebauthnCredential, cred_id)
      assert %WebauthnCredential{} = before

      body =
        authed(token)
        |> delete("/v1/auth/webauthn/credentials/#{cred_id}")
        |> json_response(200)

      # The proof fields. Revert the receipt to `%{ok: true}` and both are nil.
      assert body["created_at"] != nil,
             "receipt carried no created_at — it did not descend from the write return"

      assert {:ok, emitted, _} = DateTime.from_iso8601(body["created_at"])
      assert DateTime.compare(emitted, before.inserted_at) == :eq
      assert body["nickname"] == before.nickname
      assert body["deleted"] == before.id
      assert body["ok"] == true

      # No credential material rides the receipt.
      refute Map.has_key?(body, "cose_key")
      refute Map.has_key?(body, "credential_id")

      # …and the claim the receipt makes is true: the row is gone.
      assert Repo.get(WebauthnCredential, cred_id) == nil
    end
  end
end
