defmodule BarkparkWeb.Contract.PDSW39ResidueReceiptDifferentialTest do
  @moduledoc """
  PDS wave 39 residue — the literal-only receipts wave 39 DISPOSED but did not PAY.

  THE LAW, not the shape: a receipt lies when the value it emits does not
  DESCEND FROM THE WRITE RETURN. A bare success map beside a 200 is a sentence
  that cannot change if the store says the opposite.

  THE DIFFERENTIAL, which is the whole point: every test below asserts a field
  the REQUEST CANNOT PRODUCE — the store's surrogate `id`, the row's own
  `updated_at` stamp — read DIRECTLY through `Repo`. Revert the receipt to
  the bare success map and the key is simply ABSENT, so the assertion reds. A
  test that
  passes over both the old and the new shape proves nothing.

  Stored state is read through `Repo`, never through a second HTTP endpoint:
  two receipts agreeing with each other is not a post-condition. That is the
  Group C precedent (`pds_group_c_receipt_differential_test.exs`), and this file
  is its SUCCESSOR for the same two controllers — Group C pins that the WRITE
  landed, this file pins that the RECEIPT descends from it.

  ## Sites repaired and covered here

    * `PluginSettingsController.update/2` — `Settings.put/3` already returned the
      persisted `SettingsRecord`; the row was discarded for a literal. Repaired
      to render `ok`/`plugin_name`/`updated_at`/`updated_by`. The settings MAP is
      never echoed (this controller's read side masks it).
    * `SecretController.update/2` — `Secrets.put/3` already returned the
      persisted `SecretRecord`. Repaired to render `ok`/`id`/`name`/`updated_at`.
      NO CIPHERTEXT: `value` is absent by construction, and this file asserts its
      absence rather than trusting the diff.

  ## The third repaired site lives in the passkey file, on purpose

  `WebauthnController.delete/2` is repaired in the same change and its
  differential is in `webauthn_controller_test.exs`, beside that file's own
  ES256/P-256 software authenticator — the PDS-D501 ruling ("these land HERE,
  never a duplicated harness elsewhere"). Duplicating the ceremony to keep all
  three tests in one file would fork a harness to buy nothing.

  ## The two sites DECLARED OUT OF SCOPE, 2026-09-02

    * `PluginSettingsController.delete/2` — `Settings.delete/2` returns a bare
      `:ok`. OUT OF SCOPE: widening it to `{:ok, rec}` is a PUBLIC-CONTRACT
      change whose blast radius leaves this change's fence — Studio's
      `settings_live.ex` matches on the current return, and three `assert :ok =`
      unit assertions in `api/test/barkpark/plugins/settings_test.exs` red on the
      widen. Its post-condition is already pinned against the store by the
      Group C differential file, so nothing goes unwatched in the meantime.
    * `SecretController.delete/2` — `Secrets.delete/3` returns a bare `:ok`.
      OUT OF SCOPE for the same reason and with the same fence: three
      `assert :ok =` assertions across `api/test/barkpark/secrets_test.exs` and
      `api/test/barkpark/secrets_workspace_isolation_test.exs` red on the widen.
      Group C already pins its post-condition against the store.

  Both are named here rather than left silent: an unmentioned site is not a
  disposition. `WebauthnController.delete/2` was widened INSTEAD of deferred
  because its callee has exactly two callers — the controller repaired here and
  one test asserting only the unchanged `{:error, :not_found}` arm — so the
  widen crosses no fence at all.

  ## Two sites the filing named that were ALREADY PAID

  `AppTokenController.delete_current/2` (self-revoke) and the by-raw arm of
  `AppTokenController.delete/2` were repaired by PDS wave 40 and render
  `revoked`/`id`/`revoked_at` off `Auth.revoke_token/1`'s updated row. Nothing is
  changed there; re-deriving at HEAD is what caught it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Plugins.SettingsRecord
  alias Barkpark.Repo
  alias Barkpark.Secrets.SecretRecord

  @token "barkpark-pds-w39-residue-admin"

  setup do
    {:ok, _} = Auth.create_token(@token, "pds-w39-residue", "test", ["read", "write", "admin"])
    :ok
  end

  defp auth(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  # The GLOBAL tier is an EXPLICIT `IS NULL` read, never a `workspace_id: nil`
  # keyword (Ecto refuses a nil comparison) — the same explicit-arm discipline
  # `Barkpark.Secrets.scope_secrets/2` uses, so this reads the tier the flat
  # route wrote and can never fall through to another workspace's row.
  defp global_secret_row(name) do
    Repo.one(from(r in SecretRecord, where: r.name == ^name and is_nil(r.workspace_id)))
  end

  # ── PluginSettingsController.update/2 ──────────────────────────────────────

  describe "PUT /v1/plugins/settings/:plugin_name" do
    test "the receipt's updated_at is the STORED row's stamp, not a literal true",
         %{conn: conn} do
      name = uniq("pdsw39r-plugin-")

      body =
        conn
        |> auth()
        |> put(
          "/v1/plugins/settings/#{name}",
          Jason.encode!(%{settings: %{"api_key" => "w39r-key-1111"}})
        )
        |> json_response(200)

      stored = Repo.get(SettingsRecord, name)
      assert %SettingsRecord{} = stored

      # The proof fields: a stamp and a writer the request never carries. Revert
      # the receipt to the bare success map and both are nil here. PRESENCE IS
      # ASSERTED FIRST, on purpose: `DateTime.from_iso8601(nil)` raises before
      # `assert/2` ever runs, and a raise carries none of this message.
      assert body["updated_at"] != nil,
             "receipt carried no updated_at — it did not descend from the write return"

      assert {:ok, emitted, _} = DateTime.from_iso8601(body["updated_at"])

      assert DateTime.compare(emitted, stored.updated_at) == :eq,
             "receipt's updated_at is not the STORED row's stamp"

      assert body["updated_by"] == stored.updated_by
      assert body["updated_by"] != nil
      assert body["plugin_name"] == stored.plugin_name
      assert body["ok"] == true

      # The settings map itself is masked on read and is never echoed on write.
      refute Map.has_key?(body, "settings")
    end

    test "a SECOND write moves the receipt's stamp with the row — the value tracks the store",
         %{conn: conn} do
      name = uniq("pdsw39r-plugin-")

      first =
        conn
        |> auth()
        |> put(
          "/v1/plugins/settings/#{name}",
          Jason.encode!(%{settings: %{"api_key" => "w39r-key-2222"}})
        )
        |> json_response(200)

      second =
        conn
        |> recycle()
        |> auth()
        |> put(
          "/v1/plugins/settings/#{name}",
          Jason.encode!(%{settings: %{"api_key" => "w39r-key-3333"}})
        )
        |> json_response(200)

      stored = Repo.get(SettingsRecord, name)

      # A literal receipt is byte-identical across both writes. This one is not,
      # and the second value is the one the store now holds.
      assert second["updated_at"] != nil
      assert first["updated_at"] != second["updated_at"]

      assert {:ok, emitted, _} = DateTime.from_iso8601(second["updated_at"])
      assert DateTime.compare(emitted, stored.updated_at) == :eq
    end
  end

  # ── SecretController.update/2 ──────────────────────────────────────────────

  describe "PUT /v1/secrets/:name" do
    test "the receipt carries the STORED row's binary_id and stamp — and NO ciphertext",
         %{conn: conn} do
      name = uniq("pdsw39r_secret_")

      body =
        conn
        |> auth()
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "w39r-secret-4444"}))
        |> json_response(200)

      stored = global_secret_row(name)
      assert %SecretRecord{} = stored

      # The proof field: the store's surrogate binary_id, which appears nowhere
      # in the request. A revert to `%{ok: true}` leaves this nil.
      assert body["id"] == stored.id,
             "receipt did not descend from the write return — it echoed a literal"

      assert is_binary(body["id"])

      assert {:ok, emitted, _} = DateTime.from_iso8601(body["updated_at"])
      assert DateTime.compare(emitted, stored.updated_at) == :eq

      assert body["name"] == stored.name
      assert body["ok"] == true

      # The at-rest ciphertext (and the plaintext) never ride the write receipt:
      # `show/2` is the only verb that reveals, and it stamps a "reveal" audit
      # row to do it.
      refute Map.has_key?(body, "value")
      refute body |> Jason.encode!() |> String.contains?("w39r-secret-4444")
    end

    test "an OVERWRITE keeps the row's id and moves its stamp — the receipt follows the row",
         %{conn: conn} do
      name = uniq("pdsw39r_secret_")

      first =
        conn
        |> auth()
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "w39r-secret-5555"}))
        |> json_response(200)

      second =
        conn
        |> recycle()
        |> auth()
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "w39r-secret-6666"}))
        |> json_response(200)

      stored = global_secret_row(name)

      # The upsert replaces value/updated_at/updated_by and NEVER the id, so the
      # receipt proves both halves at once: same row, later stamp.
      assert first["id"] == second["id"]
      assert second["id"] == stored.id
      assert first["updated_at"] != second["updated_at"]

      assert {:ok, emitted, _} = DateTime.from_iso8601(second["updated_at"])
      assert DateTime.compare(emitted, stored.updated_at) == :eq
    end
  end
end
