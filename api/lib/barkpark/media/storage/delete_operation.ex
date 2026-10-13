defmodule Barkpark.Media.Storage.DeleteOperation do
  @moduledoc """
  Internal database boundary for local pending cleanup. No physical effect runs
  here. The supplied native observation is retained evidence, not permission to
  delete a later object. HTTP adoption, writer fencing and settlement are separate.
  Immutable migrations version the exact raw-row schema; unknown columns refuse.
  """
  alias Barkpark.Repo

  def commit(request, context, delete_database_rows)
      when is_map(request) and is_function(delete_database_rows, 0) do
    result =
      Repo.transaction(fn ->
        prepared =
          Ecto.Adapters.SQL.query!(Repo, "SELECT public.prepare_media_delete_v1($1::jsonb)", [
            request
          ])
          |> one!()

        case prepared["state"] do
          "prepared" ->
            if not prepared["rowStillPresent"], do: Repo.rollback(:media_row_missing)

            reservation =
              Ecto.Adapters.SQL.query!(
                Repo,
                """
                UPDATE public.media_object_reservations_v1 SET operation_id=($1::jsonb->>'operationId')::uuid
                WHERE address=public.media_object_address_v1($1::jsonb->>'expectedKey')
                  AND media_ids=ARRAY[($1::jsonb->>'mediaId')::uuid] AND operation_id IS NULL
                """,
                [request]
              )

            if reservation.num_rows != 1, do: Repo.rollback(:media_address_not_owned)

            case delete_database_rows.() do
              {:ok, snapshots} ->
                Ecto.Adapters.SQL.query!(
                  Repo,
                  """
                  UPDATE public.media_delete_operations_v1 AS o
                  SET state='pending_cleanup', asset_documents=$2::jsonb, call_context=$3::jsonb, logical_deleted_at=clock_timestamp()
                  WHERE operation_id=($1::jsonb->>'operationId')::uuid AND state='prepared'
                    AND NOT EXISTS(SELECT FROM public.media_files WHERE id=o.media_id)
                  RETURNING to_jsonb(o)
                  """,
                  [request, snapshots, context]
                )
                |> one!()

              {:error, reason} ->
                Repo.rollback(reason)
            end

          "pending_cleanup" ->
            if prepared["rowStillPresent"], do: Repo.rollback(:media_row_reappeared)

            Ecto.Adapters.SQL.query!(
              Repo,
              """
              SELECT to_jsonb(o) FROM public.media_delete_operations_v1 o
              WHERE operation_id=($1::jsonb->>'operationId')::uuid AND call_context=$2::jsonb
                AND EXISTS(SELECT FROM public.media_object_reservations_v1 r
                  WHERE r.operation_id=o.operation_id AND r.media_ids=ARRAY[o.media_id]
                    AND r.address=public.media_object_address_v1(o.request->>'expectedKey'))
              """,
              [request, context]
            )
            |> one!()
        end
      end)

    case result do
      {:ok, operation} ->
        {:ok,
         %{
           version: 1,
           state: :pending_cleanup,
           operation: operation,
           commit_state: if(Repo.in_transaction?(), do: :awaiting_outer_commit, else: :committed),
           physical_deletion_settled: false,
           recovery_allowed: false
         }}

      error ->
        error
    end
  rescue
    _e in Postgrex.Error -> {:error, :media_delete_conflict}
  end

  defp one!(%{rows: rows}) do
    case rows do
      [[value]] when is_map(value) -> value
      _ -> Repo.rollback(:media_delete_postcondition_failed)
    end
  end
end
