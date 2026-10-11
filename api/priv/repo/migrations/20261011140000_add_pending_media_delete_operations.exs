defmodule Barkpark.Repo.Migrations.AddPendingMediaDeleteOperations do
  use Ecto.Migration
  @external_resource Path.expand("../../media/delete_operations_v1.sql", __DIR__)
  @sql File.read!(@external_resource)

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
