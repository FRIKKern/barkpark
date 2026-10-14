defmodule Barkpark.Repo.Migrations.RefreshPendingMediaDeleteSourceId do
  use Ecto.Migration
  @external_resource Path.expand("../../media/delete_operations_source_id_v2.sql", __DIR__)
  @external_resource Path.expand("../../media/delete_operations_v1.sql", __DIR__)
  @sql File.read!(Path.expand("../../media/delete_operations_source_id_v2.sql", __DIR__))
  @previous File.read!(Path.expand("../../media/delete_operations_v1.sql", __DIR__))

  # Applied SQL stays immutable. Only the known source_id text column is added
  # to the exact schema gate; unrecognized columns/types must still refuse.
  for {sql, expected} <- [
        {@sql, "11f710e22a8d29ebc9f6042aba9c32e325ecd916e75a7ddfed4f09b2b9347d87"},
        {@previous, "5d8376775d8629ccdad8da98f9a5c8762a2a4d5b00b2ac78aedd3c01afa2f410"}
      ] do
    if Base.encode16(:crypto.hash(:sha256, String.replace(sql, "\r\n", "\n")), case: :lower) !=
         expected do
      raise ArgumentError, "pending media migration SQL changed; add a forward migration"
    end
  end

  def up, do: execute(@sql)

  def down do
    @previous
    |> String.split("-- @statement", trim: true)
    |> Enum.find(
      &String.starts_with?(String.trim(&1), "CREATE FUNCTION public.prepare_media_delete_v1(")
    )
    |> String.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION", global: false)
    |> execute()
  end
end
