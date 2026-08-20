defmodule Barkpark.Repo.Migrations.BackfillSingletonForHostSettingsTypes do
  @moduledoc """
  Back-compat companion to `20260726120000_add_singleton_to_schema_definitions`
  (issue #8463). The new `singleton` column defaults to `false`, which is the
  CORRECT default going forward — but every already-seeded row for the three
  real host config singletons (`siteSettings`, `navigation`, `colors`, seeded
  by `Barkpark.Seeds.Demo`) predates the column and would otherwise flip from
  "Settings" singleton editors to generic `:document_type_list` rows the
  moment an existing instance upgrades. That would change their Studio UX for
  no reason — they really are one-canonical-row config objects.

  This is a deliberate NAME-based match rather than a structural one: these
  three are host-seeded, never plugin-owned, and the set is small and stable
  (unlike a heuristic that would have to keep guessing "is this a settings
  object" for arbitrary consumer schemas — which is exactly the bug #8463
  reports). `visibility = 'private'` is an extra guard in case a workspace
  reused one of these names for something else entirely; such a row was never
  a Settings singleton pre-fix either (the old code also gated on
  `visibility == "private"`), so this migration cannot regress it.

  Set-based, non-correlated `WHERE ... IN (...)` — same shape as
  `20260722010000_backfill_chat_session_owner_workspace`, never a per-row loop
  (slow-migration law).
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE schema_definitions
    SET singleton = true
    WHERE name IN ('siteSettings', 'navigation', 'colors')
      AND visibility = 'private'
      AND singleton = false
    """)
  end

  def down do
    execute("""
    UPDATE schema_definitions
    SET singleton = false
    WHERE name IN ('siteSettings', 'navigation', 'colors')
      AND visibility = 'private'
      AND singleton = true
    """)
  end
end
