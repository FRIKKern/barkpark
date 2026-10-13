defmodule Barkpark.Repo.Migrations.AddPendingMediaDeleteOperations do
  use Ecto.Migration
  @external_resource Path.expand("../../media/delete_operations_v1.sql", __DIR__)
  @sql File.read!(@external_resource)
  @sql_sha256 "5d8376775d8629ccdad8da98f9a5c8762a2a4d5b00b2ac78aedd3c01afa2f410"

  # The migration manifest protects this file; bind its external SQL too so
  # editing that resource cannot silently fork an already-applied version.
  if Base.encode16(:crypto.hash(:sha256, String.replace(@sql, "\r\n", "\n")), case: :lower) !=
       @sql_sha256 do
    raise ArgumentError, "pending media migration SQL changed; add a forward migration"
  end

  def up do
    @sql
    |> String.split("-- @statement", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.each(&execute/1)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM public.media_delete_operations_v1) THEN
        RAISE EXCEPTION 'cannot discard unresolved media deletion operations';
      END IF;
    END $$;
    """)

    execute("DROP TRIGGER reserve_media_object_write_v1 ON public.media_files")
    execute("DROP TRIGGER reserve_media_object_delete_v1 ON public.media_files")
    execute("DROP FUNCTION public.reserve_media_object_v1()")
    execute("DROP TABLE public.media_object_reservations_v1")
    execute("DROP FUNCTION public.media_object_address_v1(text)")
    execute("DROP FUNCTION public.prepare_media_delete_v1(jsonb)")
    execute("DROP TABLE public.media_delete_operations_v1")
  end
end
