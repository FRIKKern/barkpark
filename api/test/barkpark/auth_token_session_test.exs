defmodule Barkpark.AuthTokenSessionTest do
  @moduledoc """
  Ruling #16 rework half (task-57f23825b18ab55d): a browser token sign-in now
  mints a revocable `Barkpark.Auth.TokenSession` instead of dropping the raw
  api_token straight into the session cookie. Covers the context-level API
  the controller/plug layer builds on:

    * `create_token_session/2` + `verify_token_session/1` round-trip, and the
      ciphertext-at-rest proof for the bound raw bearer.
    * `verify_token_session/1` re-checks the UNDERLYING api_token on every
      call (revoked/expired token kills a perfectly live session row).
    * `revoke_token_session/1` DELETES the row (not a `revoked_at` flag) — the
      logout primitive, and the DB-level twin of the HTTP-level criterion in
      `SessionControllerTest` ("replaying a copied cookie no longer
      authenticates").
    * `resolve_session_credential/2` — the one function every browser-session
      read call-site funnels through: new session-id path wins when present
      (even when dead — it never silently falls back to the legacy raw key),
      legacy raw-token path is the one-release transition fallback.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.TokenSession

  defp insert_token(raw, attrs \\ %{}) do
    base = %{
      token_hash: ApiToken.hash_token(raw),
      label: "token-session-test",
      dataset: "test",
      permissions: ["read"]
    }

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    token
  end

  defp seconds_from_now(secs) do
    DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.truncate(:second)
  end

  describe "create_token_session/2 + verify_token_session/1 — round trip" do
    test "mints an opaque session id, distinct from the raw bearer, that resolves back to it" do
      raw = "session-rt-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, session_id} = Auth.create_token_session(raw, token)
      assert is_binary(session_id)
      refute session_id == raw

      assert {:ok, verified_token, ^raw} = Auth.verify_token_session(session_id)
      assert verified_token.id == token.id
    end

    test "the bound raw bearer is Cloak-encrypted at rest — the ciphertext column never holds it",
         %{} do
      raw = "session-ciphertext-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      {:ok, session_id} = Auth.create_token_session(raw, token)

      ciphertext =
        from(s in "token_sessions",
          where: s.session_hash == ^TokenSession.hash_token(session_id),
          select: type(s.raw_token, :binary)
        )
        |> Repo.one()

      refute is_nil(ciphertext)
      refute ciphertext == raw
      refute String.contains?(ciphertext, raw)
    end

    test "an unknown session id does not verify" do
      assert Auth.verify_token_session("bpts_not-a-real-session-id") == :error
    end

    test "a garbage/empty input does not verify" do
      assert Auth.verify_token_session("") == :error
      assert Auth.verify_token_session(nil) == :error
    end
  end

  describe "verify_token_session/1 — the underlying api_token is re-checked live" do
    test "a REVOKED api_token kills a perfectly live session row" do
      raw = "session-revoked-token-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      {:ok, session_id} = Auth.create_token_session(raw, token)

      assert {:ok, _, _} = Auth.verify_token_session(session_id)

      {:ok, _revoked} = Auth.revoke_token(token)

      assert Auth.verify_token_session(session_id) == :error
    end

    test "an EXPIRED api_token kills a perfectly live session row" do
      raw = "session-expired-token-" <> Ecto.UUID.generate()
      token = insert_token(raw, %{expires_at: seconds_from_now(-10)})
      {:ok, session_id} = Auth.create_token_session(raw, token)

      assert Auth.verify_token_session(session_id) == :error
    end
  end

  describe "revoke_token_session/1 — logout, DELETES the row" do
    test "a revoked session id no longer verifies, and the row is gone (not just flagged)" do
      raw = "session-logout-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      {:ok, session_id} = Auth.create_token_session(raw, token)

      assert {:ok, 1} = Auth.revoke_token_session(session_id)
      assert Auth.verify_token_session(session_id) == :error

      # DELETED, not merely flagged — a live row (even revoked_at-flagged)
      # still holds a decryptable credential (the LoginTicket retention
      # lesson this schema's moduledoc cites).
      row =
        from(s in TokenSession, where: s.session_hash == ^TokenSession.hash_token(session_id))
        |> Repo.one()

      assert row == nil
    end

    test "revoking twice (or an unknown session id) is idempotent, not an error" do
      raw = "session-double-logout-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      {:ok, session_id} = Auth.create_token_session(raw, token)

      assert {:ok, 1} = Auth.revoke_token_session(session_id)
      assert {:ok, 0} = Auth.revoke_token_session(session_id)
      assert {:ok, 0} = Auth.revoke_token_session("bpts_never-existed")
    end
  end

  describe "resolve_session_credential/2 — the one funnel every read call-site uses" do
    test "the new session-id path wins when present and live, legacy arg ignored" do
      raw = "resolve-new-path-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      {:ok, session_id} = Auth.create_token_session(raw, token)

      assert {:ok, resolved, ^raw} =
               Auth.resolve_session_credential(session_id, "some-other-legacy-raw")

      assert resolved.id == token.id
    end

    test "falls back to the legacy raw-token path when no session id is present" do
      raw = "resolve-legacy-path-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, resolved, ^raw} = Auth.resolve_session_credential(nil, raw)
      assert resolved.id == token.id
      assert Auth.resolve_session_credential("", raw) == {:ok, resolved, raw}
    end

    test "a DEAD session id does NOT fall back to the legacy raw token, even if present" do
      raw = "resolve-dead-no-fallback-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      {:ok, session_id} = Auth.create_token_session(raw, token)
      {:ok, 1} = Auth.revoke_token_session(session_id)

      # If this fell back to the legacy arg, it would resolve via `raw` and
      # return {:ok, token, raw} — the exact behaviour that would silently
      # reopen the hole: a dead session, still accepted via its own raw
      # bearer landing in the legacy slot.
      assert Auth.resolve_session_credential(session_id, raw) == :error
    end

    test "both absent resolves to :error" do
      assert Auth.resolve_session_credential(nil, nil) == :error
      assert Auth.resolve_session_credential("", "") == :error
    end
  end

  describe "session_credential_present?/2" do
    test "true when either key is a non-blank string, false when both are blank" do
      assert Auth.session_credential_present?("sid", nil)
      assert Auth.session_credential_present?(nil, "raw")
      assert Auth.session_credential_present?("sid", "raw")
      refute Auth.session_credential_present?(nil, nil)
      refute Auth.session_credential_present?("", "")
    end
  end
end
