defmodule Barkpark.Repo.Migrations.StripDeadMinLen2typoFromSurfaceConfigs do
  @moduledoc """
  `typo_policy.min_len_2typo` never had a reader — it was introduced with the
  rest of the block (48fe5985bf, May 2026) and no retriever ever consulted it.
  It is gone from the shipped defaults in this change, and the config PUT now
  refuses `typo_policy` keys nothing reads.

  Existing rows carry it (every row `seed_defaults!/0` ever wrote does), and an
  admin's own round-trip is GET → edit → PUT: without this strip, the very first
  PUT after the upgrade would 422 on a key the server itself put there. Drop the
  key from every stored row so no row can fail its own round-trip.

  Irreversible by design in the `down` direction only in the sense that the key
  carried no information: restoring it would re-add a value nothing reads, so
  `down` is a no-op rather than a lie about round-tripping.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE search_surface_config
       SET typo_policy = typo_policy - 'min_len_2typo'
     WHERE jsonb_exists(typo_policy, 'min_len_2typo')
    """)
  end

  def down, do: :ok
end
