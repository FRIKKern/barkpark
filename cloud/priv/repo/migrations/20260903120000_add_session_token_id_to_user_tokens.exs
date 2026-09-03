defmodule BarkparkCloud.Repo.Migrations.AddSessionTokenIdToUserTokens do
  use Ecto.Migration

  # THE COLUMN THAT MAKES A LIVE STREAM REVOCABLE PER DEVICE
  # (cch-w53-bl-per-row-session-revoke-does-not-end-that-sessions-stream).
  #
  # `GET /v1/events` authenticates ONCE, at connect, and the credential is gone
  # by the time the loop parks (an `?ticket=` is BURNED inside the connect
  # transaction). So the parked loop could only ever re-ask a question about the
  # USER — "does this user still hold at least one live session?" — which is
  # true by construction on the per-row path: the acting device that pressed
  # Revoke IS a live session. The revoked device's stream kept delivering.
  #
  # `session_token_id` is the missing edge: a `context = "sse"` ticket row
  # points at the `context = "session"` row that minted it, so the loop can
  # recheck THAT row instead of a user-wide count. Self-referential on purpose —
  # `user_tokens` is the polymorphic credential table and both endpoints of this
  # edge live in it.
  #
  # ADDITIVE-NULLABLE, NO DEFAULT, NO BACKFILL, following the rule 20260629120100
  # states for this table and 20260728120000 (`origin`) restates. A pre-existing
  # ticket row keeps `session_token_id = NULL`, and NULL is a MEANINGFUL value
  # here, not a gap to be filled: it means "this stream is not bound to a
  # session row", and the loop falls back to the user-wide liveness check it used
  # before. Inventing a binding for an old row would bind a stream to the wrong
  # device — the opposite of the bug being closed.
  #
  # `on_delete: :nilify_all` rather than `:delete_all`: dropping a session row
  # must never silently delete ticket rows (they are the audit of who opened a
  # stream), and nilifying degrades that ticket to the user-wide fallback, which
  # is the conservative direction.
  #
  # BLUE/GREEN IS ONE-DIRECTIONAL, exactly as 20260728120000 spells out: an OLD
  # node against the NEW schema never selects the column and is fine; a NEW node
  # against an UN-MIGRATED DB fails EVERY `UserToken` select (Ecto selects the
  # full field list), which breaks all authenticated traffic. Land this BEFORE or
  # WITH the deploy, never after.
  def change do
    alter table(:user_tokens) do
      add :session_token_id,
          references(:user_tokens, type: :binary_id, on_delete: :nilify_all)
    end

    # The revoke path queries `session_token_id + context` to sweep the tickets a
    # revoked session minted; without this it is a sequential scan of every
    # credential row in the table.
    create index(:user_tokens, [:session_token_id])
  end
end
