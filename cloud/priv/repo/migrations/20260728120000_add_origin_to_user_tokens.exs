defmodule BarkparkCloud.Repo.Migrations.AddOriginToUserTokens do
  use Ecto.Migration

  # Session PROVENANCE (gr-p5-session-provenance). The active-sessions list shows
  # a device and an IP but never WHERE the session came from, so the SPA cannot
  # honestly say "via device link". `origin` is the mint-time answer, written only
  # by the write sites that already hold it.
  #
  # ADDITIVE-NULLABLE, NO DEFAULT, NO BACKFILL — deliberately, following the rule
  # 20260629120100 states for this same table ("every new column is nullable /
  # defaulted so pre-existing session rows are untouched"). Every row that
  # predates this migration keeps `origin = NULL`, which the API renders as
  # `null` and the SPA renders as nothing: "we don't know" is the truth about
  # those rows, and a backfilled guess would be the invention this epic exists to
  # remove.
  #
  # BLUE/GREEN IS ONE-DIRECTIONAL HERE. An OLD node against the NEW schema is
  # fine (it never selects the column). A NEW node against an UN-MIGRATED DB
  # fails EVERY `UserToken` select — Ecto selects the full field list — which
  # breaks session verification, i.e. all authenticated traffic. So this
  # migration lands BEFORE or WITH the deploy, never after it.
  def change do
    alter table(:user_tokens) do
      add :origin, :string
    end
  end
end
