defmodule Barkpark.Media.Storage.LocalWrite do
  @moduledoc """
  Managed local blob effects share the pending-delete database lock before I/O.
  Ordinary servers keep their existing path. An unresolved operation forbids
  writes to its Windows address and refuses unsupported aliases conservatively.

  A database lock may disappear during I/O. Physical-effect admission therefore
  retains owner death and failed/unverified effects for reconciliation. This is
  not native cleanup, a complete writer census or permission to recover.
  """
  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.ManagedRuntime.WriteAdmission.Door
  alias Barkpark.Repo

  @storage_error {:error, :storage_unavailable}

  def run(key, effect) when is_binary(key) and is_function(effect, 0) do
    if Door.enabled?(), do: admitted(key, effect), else: effect.()
  end

  defp admitted(key, effect) do
    server = Door.server()

    case checkout(server) do
      {:ok, ticket} ->
        marker = {__MODULE__, make_ref()}
        Process.put(marker, false)

        try do
          result =
            Repo.transaction(
              fn ->
                # Same first lock as prepare_media_delete_v1. It covers the
                # check and physical effect, including keys without a row yet.
                Repo.query!("LOCK TABLE public.media_files IN SHARE ROW EXCLUSIVE MODE")
                refuse_pending(key)
                Process.put(marker, true)
                effect.()
              end,
              timeout: 60_000
            )

          case result do
            {:ok, value} -> finish(server, ticket, value, Process.get(marker))
            {:error, _} -> finish(server, ticket, @storage_error, Process.get(marker))
          end
        rescue
          _error in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
            finish(server, ticket, @storage_error, Process.get(marker))
        catch
          kind, reason ->
            retain_or_settle(server, ticket, Process.get(marker))
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          Process.delete(marker)
        end

      _ ->
        @storage_error
    end
  end

  defp checkout(nil), do: {:error, :unconfigured}

  defp checkout(server) do
    WriteAdmission.checkout_effect(server)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp finish(server, ticket, value, started) do
    uncertain =
      started and
        (match?({:error, _}, value) or match?({:ok, %{stored: :unverified}}, value))

    case retain_or_settle(server, ticket, uncertain) do
      :ok -> value
      _ -> @storage_error
    end
  end

  defp retain_or_settle(server, ticket, true),
    do: safe_call(fn -> WriteAdmission.uncertain(server, ticket) end)

  defp retain_or_settle(server, ticket, false),
    do: safe_call(fn -> WriteAdmission.checkin(server, ticket) end)

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp refuse_pending(key) do
    case Repo.query!(
           "SELECT request->>'expectedKey',state FROM public.media_delete_operations_v1"
         ).rows do
      [] ->
        :ok

      rows ->
        unless Enum.all?(rows, fn
                 [retained_key, state] when is_binary(retained_key) ->
                   state in ["prepared", "pending_cleanup"] and windows_key?(retained_key)

                 _ ->
                   false
               end),
               do: Repo.rollback(:media_cleanup_unknown)

        check_address(key)
    end
  end

  defp check_address(key) do
    # NTFS aliases are broader than SQL's C collation. While cleanup is
    # unresolved only its proven ASCII relative namespace can be compared.
    # Unicode/legacy ordinary writes remain unchanged with no pending operation.
    unless windows_key?(key), do: Repo.rollback(:media_cleanup_unknown_address)

    case Repo.query!(
           """
           SELECT EXISTS(
             SELECT FROM public.media_delete_operations_v1 o
             WHERE o.state NOT IN ('prepared','pending_cleanup')
               OR jsonb_typeof(o.request->'expectedKey') IS DISTINCT FROM 'string'
               OR public.media_object_address_v1(o.request->>'expectedKey')=public.media_object_address_v1($1)
           ) OR EXISTS(
             SELECT FROM public.media_object_reservations_v1 r
             WHERE r.address=public.media_object_address_v1($1) AND r.operation_id IS NOT NULL
           )
           """,
           [key]
         ).rows do
      [[false]] -> :ok
      _ -> Repo.rollback(:media_cleanup_pending)
    end
  end

  defp windows_key?(key) do
    # The generated key alphabet excludes NTFS short-name and device/stream
    # spellings as well as separators with alternate Windows semantics.
    byte_size(key) in 1..4096 and Regex.match?(~r/\A[A-Za-z0-9._\/-]+\z/, key) and
      Enum.all?(String.split(key, "/"), fn part ->
        part not in ["", ".", ".."] and not String.ends_with?(part, [".", " "]) and
          not Regex.match?(~r/\A(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|\z)/i, part)
      end)
  end
end
