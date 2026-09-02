defmodule BarkparkWeb.WebauthnController do
  @moduledoc """
  WebAuthn / passkey HTTP surface (`/v1/auth/webauthn/*`).

  Passkeys are a **login factor** (usernameless sign-in) AND a **step-up factor**
  (a phishing-resistant way to clear a `mfa_required` challenge). All crypto is
  delegated to `wax` via `Barkpark.Accounts.Webauthn` — this controller only
  moves bytes and issues sessions.

  Each ceremony is stateless across its two round-trips: the challenge step
  returns a short-lived signed `challenge_token` (a `Phoenix.Token` over the
  challenge bytes) which the client echoes back on the verify step — no
  server-side challenge store, works identically for API, browser, and tests.
  Binary fields from `navigator.credentials` are base64url (no padding).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{User, Webauthn}
  alias Barkpark.Audit
  alias BarkparkWeb.SessionIssuer

  @reg_salt "webauthn-register"
  @auth_salt "webauthn-authenticate"
  @challenge_max_age 300

  # ── Registration (session-gated: enrol a passkey for the logged-in user) ─────

  def register_challenge(conn, _params) do
    user = conn.assigns.current_user
    challenge = Webauthn.registration_challenge()

    json(conn, %{
      challenge: b64(challenge.bytes),
      challenge_token: sign(@reg_salt, challenge.bytes),
      rp_id: Webauthn.rp_id(),
      user: %{id: b64(user.id), name: user.email, display_name: user.email}
    })
  end

  def register(conn, %{
        "attestation_object" => att_b64,
        "client_data_json" => cdj_b64,
        "challenge_token" => token
      }) do
    user = conn.assigns.current_user

    with {:ok, bytes} <- verify_token(@reg_salt, token),
         {:ok, att} <- decode64(att_b64),
         {:ok, cdj} <- decode64(cdj_b64),
         {:ok, cred} <-
           Webauthn.verify_registration(user, att, cdj, bytes, nickname: conn.params["nickname"]) do
      Audit.emit(%{
        category: "auth",
        action: "passkey_registered",
        subject: user.id,
        actor_type: "user",
        actor_id: user.id,
        metadata: %{"credential" => cred.id}
      })

      conn
      |> put_status(:created)
      |> json(%{ok: true, credential: %{id: cred.id, nickname: cred.nickname}})
    else
      _ -> invalid_passkey(conn, "registration could not be verified")
    end
  end

  def register(conn, _),
    do:
      error(
        conn,
        422,
        "bad_request",
        "attestation_object, client_data_json and challenge_token are required"
      )

  # ── Login (public: usernameless passkey sign-in → a fresh session) ───────────

  def login_challenge(conn, _params) do
    challenge = Webauthn.authentication_challenge()

    json(conn, %{
      challenge: b64(challenge.bytes),
      challenge_token: sign(@auth_salt, challenge.bytes),
      rp_id: Webauthn.rp_id()
    })
  end

  def login(conn, %{
        "credential_id" => cid_b64,
        "authenticator_data" => ad_b64,
        "signature" => sig_b64,
        "client_data_json" => cdj_b64,
        "challenge_token" => token
      }) do
    with {:ok, bytes} <- verify_token(@auth_salt, token),
         {:ok, cid} <- decode64(cid_b64),
         {:ok, ad} <- decode64(ad_b64),
         {:ok, sig} <- decode64(sig_b64),
         {:ok, cdj} <- decode64(cdj_b64),
         {:ok, cred} <- Webauthn.verify_authentication(cid, ad, sig, cdj, bytes),
         %User{} = user <- Accounts.get_user(cred.user_id) do
      Audit.emit(%{
        category: "auth",
        action: "passkey_login",
        subject: user.id,
        actor_type: "user",
        actor_id: user.id,
        metadata: %{"credential" => cred.id}
      })

      # A passkey is a strong, phishing-resistant factor — mint an already-fresh
      # session so a sensitive action right after login isn't re-challenged.
      SessionIssuer.issue(conn, user, mfa_verified: true)
    else
      _ ->
        error(
          conn,
          401,
          "invalid_passkey",
          "the passkey could not be verified",
          "retry the passkey prompt; if it keeps failing, sign in another way"
        )
    end
  end

  def login(conn, _),
    do:
      error(
        conn,
        422,
        "bad_request",
        "credential_id, authenticator_data, signature, client_data_json and challenge_token are required"
      )

  # ── Step-up (session-gated: a passkey clears a mfa_required challenge) ────────

  def step_up_challenge(conn, params), do: login_challenge(conn, params)

  def step_up(conn, %{
        "credential_id" => cid_b64,
        "authenticator_data" => ad_b64,
        "signature" => sig_b64,
        "client_data_json" => cdj_b64,
        "challenge_token" => token
      }) do
    user = conn.assigns.current_user
    session = conn.assigns.current_user_session

    with {:ok, bytes} <- verify_token(@auth_salt, token),
         {:ok, cid} <- decode64(cid_b64),
         {:ok, ad} <- decode64(ad_b64),
         {:ok, sig} <- decode64(sig_b64),
         {:ok, cdj} <- decode64(cdj_b64),
         {:ok, cred} <- Webauthn.verify_authentication(cid, ad, sig, cdj, bytes),
         true <- cred.user_id == user.id,
         {:ok, session} <- Accounts.stamp_session_mfa(session) do
      Audit.emit(%{
        category: "auth",
        action: "mfa_passed",
        subject: user.id,
        actor_type: "user",
        actor_id: user.id,
        metadata: %{"factor" => "passkey"}
      })

      json(conn, %{
        ok: true,
        factor: "passkey",
        fresh_until:
          DateTime.add(
            session.mfa_verified_at,
            Accounts.UserSession.default_step_up_window(),
            :second
          )
      })
    else
      _ ->
        Audit.emit(%{
          category: "auth",
          action: "mfa_failed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"context" => "step_up", "factor" => "passkey"}
        })

        error(conn, 422, "invalid_passkey", "the passkey could not be verified")
    end
  end

  def step_up(conn, _),
    do: error(conn, 422, "bad_request", "a passkey assertion is required")

  # ── Management (session-gated) ───────────────────────────────────────────────

  def index(conn, _params) do
    creds =
      conn.assigns.current_user
      |> Webauthn.list_credentials()
      |> Enum.map(fn c ->
        %{id: c.id, nickname: c.nickname, last_used_at: c.last_used_at, created_at: c.inserted_at}
      end)

    json(conn, %{credentials: creds})
  end

  def delete(conn, %{"id" => id}) do
    case Webauthn.delete_credential(conn.assigns.current_user, id) do
      # RECEIPT LAW (pds wave 39 residue): `Webauthn.delete_credential/2` was
      # WIDENED to hand back the row `Repo.delete/2` removed, so this receipt
      # names what actually left the store instead of asserting a bare literal
      # beside a 200. `nickname` and `created_at` are the row's own fields — the
      # request carries the `:id` path param and nothing else — so reverting to the
      # bare success map drops them and the differential reds. `ok` is kept, and
      # kept `true`, so the wire contract is unchanged for existing callers; it
      # is the CONTENT beside it that descends. Field names mirror `index/2`'s
      # projection rather than inventing a second shape for the same row. No
      # credential material (`credential_id`, `cose_key`) is ever emitted.
      {:ok, cred} ->
        json(conn, %{
          ok: true,
          deleted: cred.id,
          nickname: cred.nickname,
          created_at: cred.inserted_at
        })

      {:error, :not_found} ->
        error(conn, 404, "not_found", "no such passkey")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp sign(salt, bytes), do: Phoenix.Token.sign(BarkparkWeb.Endpoint, salt, bytes)

  defp verify_token(salt, token) when is_binary(token),
    do: Phoenix.Token.verify(BarkparkWeb.Endpoint, salt, token, max_age: @challenge_max_age)

  defp verify_token(_salt, _), do: {:error, :missing_token}

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp decode64(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.decode64(s, padding: false)
    end
  end

  defp decode64(_), do: :error

  defp invalid_passkey(conn, msg), do: error(conn, 422, "invalid_passkey", msg)

  defp error(conn, status, code, message, hint \\ nil) do
    body = %{code: code, message: message}
    body = if hint, do: Map.put(body, :hint, hint), else: body

    conn
    |> put_status(status)
    |> json(%{error: body})
  end
end
