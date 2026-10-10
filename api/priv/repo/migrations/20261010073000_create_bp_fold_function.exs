defmodule Barkpark.Repo.Migrations.CreateBpFoldFunction do
  use Ecto.Migration

  @moduledoc """
  `bp_fold(text)` — the Norwegian search fold (task-1429eb7cfc6217ea).

  æ→ae, ø→o, å→a (either case), ASCII A–Z lower-cased, then the ASCII
  transliterations aa→a and oe→o, so "Ærlig"/"aerlig", "økonomi"/"okonomi"/
  "oekonomi" and "årsrapport"/"arsrapport"/"aarsrapport" fold to one string.
  `Barkpark.Search.Fold.fold/1` is the Elixir twin; a table test pins the two
  equal. Lower-casing is ASCII-only through `translate`, never `lower()`, so
  the result cannot depend on the database's locale.

  A function only: no table is touched, no index is built. The retriever
  applies it to `documents.title` in the same filter scan its other title arms
  already run.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION bp_fold(t text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT replace(replace(
        translate(
          replace(replace(replace(replace(replace(replace(t,
            'Æ', 'ae'), 'æ', 'ae'), 'Ø', 'o'), 'ø', 'o'), 'Å', 'a'), 'å', 'a'),
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'),
        'aa', 'a'), 'oe', 'o')
    $$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS bp_fold(text)")
  end
end
