defmodule Barkpark.Repo.Migrations.AddContextHeadroomToChatSessions do
  use Ecto.Migration

  @moduledoc """
  Per-turn context-headroom snapshot (epic studio-claude-chat, wave 2, charter D19).

  The denormalised session totals (`input_tokens`/`output_tokens`) are `inc:`-summed
  ACROSS turns and cannot drive a "how full is the context window right now" ring.
  The ring needs the LATEST turn's window occupancy, so we add two nullable snapshot
  columns, both SET (never inc) from the most-recent result frame:

    * `last_context_tokens` — input + cache_read + cache_creation + output of the
      most-recent result frame (the tokens riding in the model's context on that turn).
    * `context_window` — `modelUsage.<model>.contextWindow` captured from the frame.
      NEVER a hardcoded model→window map (goes stale silently); we read whatever the
      CLI reports for the answering model.

  Both nullable: a pre-migration session, or a session with no result yet, has an
  UNKNOWN window — the ring renders hollow + an em-dash, never a fake arc.
  """

  def change do
    alter table(:chat_sessions) do
      add :last_context_tokens, :integer
      add :context_window, :integer
    end
  end
end
