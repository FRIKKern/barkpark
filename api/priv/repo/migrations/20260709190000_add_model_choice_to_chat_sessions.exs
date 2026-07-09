defmodule Barkpark.Repo.Migrations.AddModelChoiceToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      # The USER'S picked model alias (haiku/sonnet/opus/fable), nil = CLI
      # default. Distinct from `model` (the observed answering model off the
      # result frame) — choice is intent, model is fact.
      add :model_choice, :string
    end
  end
end
