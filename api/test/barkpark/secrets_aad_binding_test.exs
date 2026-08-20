defmodule Barkpark.SecretsAadBindingTest do
  @moduledoc """
  W22 slice-3 (connectors-secrets-aad-binding, D201 option C) — the CRYPTOGRAPHIC
  tenant wall for the run-secrets store.

  RED-FIRST provenance: this file began as the delivered swap-attack probe whose
  two leak assertions (`{:ok, plaintext}` under ws-B and `plaintext == get`)
  passed 2/2 against unmodified origin/main — the D196a SQL-only wall let a
  physically relocated scoped row decrypt under the new owner (Cloak's constant
  AAD carried no owner binding). Those assertions are FLIPPED below to the
  post-fix expectation (`{:error, :not_found}` / `nil`): once `value` rides the
  per-`(workspace_id, "run-secrets")` DEK via `FieldCipher`, a row moved to
  another workspace is decrypted under the WRONG DEK — GCM tag mismatch → the
  read verbs seal it to opaque-absent.

  ## Why this proves the CRYPTO layer, not the SQL layer

  After the raw `UPDATE secrets SET workspace_id = ws_b`, the row's
  `workspace_id` genuinely IS ws-B, so `fetch/2`'s SQL scope gate is behaving
  CORRECTLY when it serves the row to ws-B — there is nothing to fix at SQL.
  The only thing that can deny the read is that DECRYPTION fails under ws-B's key
  material. The own-scope survivor assertion (`reveal` under ws-A after the swap)
  stays `{:error, :not_found}` in BOTH worlds — the row genuinely left ws-A.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.Secrets

  @name "slack_bot_token"
  @plaintext "xoxb-ws-a-super-secret-value-1234"

  describe "swap attack — a relocated scoped row fails to decrypt under the new owner (D201)" do
    test "a row raw-SQL moved from ws-A to ws-B no longer reveals its plaintext under ws-B" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      # ws-A stores a scoped secret through the real store (FieldCipher envelope
      # keyed by DEK(ws-A, "run-secrets")).
      assert {:ok, _} = Secrets.put(@name, @plaintext, actor: "alice", scope: ws_a.id)
      assert {:ok, @plaintext} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)

      # THE ATTACK: physically relocate the row to ws-B at the SQL layer,
      # bypassing every context-module scope gate. This is a DB-admin / raw-SQL
      # / restore-into-wrong-tenant threat, exactly what DEK binding defends.
      {moved, _} =
        from(s in Barkpark.Secrets.SecretRecord,
          where: s.name == ^@name and s.workspace_id == ^ws_a.id
        )
        |> Repo.update_all(set: [workspace_id: ws_b.id])

      assert moved == 1, "expected exactly one row relocated ws-A -> ws-B"

      # The row genuinely left ws-A — absent there, in both the pre- and post-fix
      # worlds (the SQL gate no longer matches ws-A).
      assert {:error, :not_found} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)

      # ── THE WALL (post-fix; was `{:ok, @plaintext}` RED baseline) ──
      # The SQL gate LEGITIMATELY serves the relocated row to ws-B, but the
      # envelope was sealed under DEK(ws-A, "run-secrets"); decrypting under
      # DEK(ws-B, "run-secrets") fails the GCM tag, so `reveal` seals it to
      # opaque-absent. Plaintext never crosses the tenant wall.
      assert {:error, :not_found} = Secrets.reveal(@name, actor: "mallory", scope: ws_b.id)
    end

    test "the crypto denial also seals the cheap, un-audited get/2 resolver path" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, @plaintext, scope: ws_a.id)

      {1, _} =
        from(s in Barkpark.Secrets.SecretRecord,
          where: s.name == ^@name and s.workspace_id == ^ws_a.id
        )
        |> Repo.update_all(set: [workspace_id: ws_b.id])

      # get/2 (no audit) is sealed the same way — the wall is store-wide, not a
      # reveal-only artifact. (Was `@plaintext == get(...)` in the RED baseline.)
      assert nil == Secrets.get(@name, ws_b.id)
      assert nil == Secrets.get(@name, ws_a.id)
    end

    test "a scoped secret still round-trips under its OWN workspace (wall isn't a blanket denial)" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, @plaintext, actor: "alice", scope: ws_a.id)

      # Own-scope survivor — the DEK binding must not break legitimate reads.
      assert {:ok, @plaintext} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)
      assert @plaintext == Secrets.get(@name, ws_a.id)
    end
  end
end
