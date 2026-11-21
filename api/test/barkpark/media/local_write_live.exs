# Owned fresh release/database only. C105_PROOF_INPUT carries native-observed
# originals; no SQL sandbox, real library or physical cleanup authority.
defmodule Barkpark.Media.Storage.LocalWriteLiveTest do
  use ExUnit.Case, async: false
  alias Barkpark.{Content, Media, Repo}
  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.Media.Blobstore.Local
  alias Barkpark.Media.Storage.LocalWrite

  defp query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)

  defp gate(fun) do
    previous = Application.get_env(:barkpark, :write_admission)
    # Each phase boots a fresh VM; its integer counter can repeat. Retained
    # journals must never be reused or removed just to make a fixture start.
    instance = "live-effect-#{Ecto.UUID.generate()}"
    journal = Path.join(System.fetch_env!("C109_JOURNALS"), instance <> ".dets")
    options = [journal: journal, instance_id: instance, initialize: true]
    {:ok, server} = WriteAdmission.start_link(options)
    Process.unlink(server)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    try do
      fun.(server, options)
    after
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(server), do: GenServer.stop(server)
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: flunk("owned database/admission condition timed out")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end

  defp waiting(pid) do
    query(
      "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND relation='media_files'::regclass AND NOT granted)",
      [pid]
    ).rows == [[true]]
  end

  defp exact(request) do
    bytes = File.read!(Path.join(request["root"]["path"], request["expectedKey"]))
    assert byte_size(bytes) == request["file"]["bytes"]
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == request["file"]["sha256"]
    bytes
  end

  test "managed original-blob reservation, real concurrent rollback and interrupted effect" do
    input = System.fetch_env!("C105_PROOF_INPUT") |> File.read!() |> Jason.decode!()
    [target | _] = input["fixtures"]
    request = target["request"]
    key = request["expectedKey"]
    original = exact(request)
    parent = self()

    case input["phase"] do
      "writer" ->
        gate(fn server, _ ->
          writer =
            Task.async(fn ->
              LocalWrite.run(key, fn ->
                assert :ok = File.write(Media.file_path(key), original)
                [[pid]] = query("SELECT pg_backend_pid()").rows
                send(parent, {:writer_in_io, self(), pid})
                receive do: (:settle -> :ok)
              end)
            end)

          assert_receive {:writer_in_io, writer_pid, _}, 15_000

          deletion =
            Task.async(fn ->
              Content.Broadcast.with_deferred_queue(fn ->
                Repo.transaction(fn ->
                  [[pid]] = query("SELECT pg_backend_pid()").rows
                  send(parent, {:delete_started, self(), pid})

                  assert {:ok, receipt} =
                           Media.commit_pending_delete(request, where_used: :cascade)

                  assert receipt.commit_state == :awaiting_outer_commit
                  send(parent, {:delete_pending, self()})
                  receive do: (:rollback -> Repo.rollback(:owned_rollback))
                end)
              end)
            end)

          assert_receive {:delete_started, _, delete_backend}, 15_000
          eventually(fn -> waiting(delete_backend) end)
          refute_received {:delete_pending, _}
          exact(request)
          send(writer_pid, :settle)
          assert Task.await(writer, 15_000) == :ok
          assert_receive {:delete_pending, delete_pid}, 15_000

          next_writer =
            Task.async(fn ->
              Repo.checkout(fn ->
                [[pid]] = query("SELECT pg_backend_pid()").rows
                send(parent, {:next_writer, pid})
                Local.put_bytes(key, original, [])
              end)
            end)

          assert_receive {:next_writer, write_backend}, 15_000
          eventually(fn -> waiting(write_backend) end)
          exact(request)
          send(delete_pid, :rollback)
          assert Task.await(deletion, 15_000) == {:error, :owned_rollback}
          assert {:ok, %{stored: size}} = Task.await(next_writer, 15_000)
          assert size == byte_size(original)
          assert query("SELECT count(*) FROM media_delete_operations_v1").rows == [[0]]

          assert query("SELECT to_jsonb(m) FROM media_files m WHERE id=$1::text::uuid", [
                   request["mediaId"]
                 ]).rows == [[target["rawRow"]]]

          assert %{phase: :open, pending: 0} = WriteAdmission.status(server)
          exact(request)
        end)

      phase when phase in ["fence", "fence-resume"] ->
        gate(fn server, _ ->
          assert query(
                   "SELECT state FROM media_delete_operations_v1 WHERE operation_id=$1::text::uuid",
                   [request["operationId"]]
                 ).rows == [["pending_cleanup"]]

          source = Path.join(System.fetch_env!("C109_JOURNALS"), phase <> "-source.bin")
          File.write!(source, "replacement")

          for alias_key <- [key, String.upcase(key)] do
            assert {:error, :storage_unavailable} = Local.put_bytes(alias_key, "replacement", [])
            assert {:error, :storage_unavailable} = Local.put_file(alias_key, source, [])
            assert {:error, :storage_unavailable} = Local.delete(alias_key)
            exact(request)
          end

          assert File.read!(source) == "replacement"

          assert {:error, :storage_unavailable} =
                   Local.put_bytes(String.replace(key, "/", "\\"), "replacement", [])

          assert {:error, :storage_unavailable} =
                   Local.put_bytes("c109/Chø.bin", "replacement", [])

          for alias_key <- ["c109/SHORTN~1.BIN", "c109/CONOUT$", key <> ":stream"] do
            assert {:error, :storage_unavailable} = Local.put_bytes(alias_key, "replacement", [])
          end

          unrelated = "c109/#{phase}/unrelated.bin"
          assert {:ok, %{stored: 5}} = Local.put_bytes(unrelated, "other", [])
          assert File.read!(Media.file_path(unrelated)) == "other"
          assert :ok = Local.delete(unrelated)
          assert %{phase: :open, pending: 0} = WriteAdmission.status(server)
          exact(request)
        end)

      "effect-failure" ->
        for failure <- [:owner_death, :connection_death] do
          gate(fn server, options ->
            file_key = "c109/#{failure}.bin"

            {worker, monitor} =
              spawn_monitor(fn ->
                result =
                  LocalWrite.run(file_key, fn ->
                    File.mkdir_p!(Path.dirname(Media.file_path(file_key)))
                    assert :ok = File.write(Media.file_path(file_key), "escaped-effect")
                    [[pid]] = query("SELECT pg_backend_pid()").rows
                    send(parent, {:effect_started, self(), pid})
                    receive do: (:finish -> :ok)
                  end)

                send(parent, {:effect_result, result})
              end)

            assert_receive {:effect_started, ^worker, backend}, 15_000
            assert File.read!(Media.file_path(file_key)) == "escaped-effect"

            if failure == :owner_death do
              Process.exit(worker, :kill)
            else
              assert query("SELECT pg_terminate_backend($1)", [backend]).rows == [[true]]

              eventually(fn ->
                query("SELECT NOT EXISTS(SELECT FROM pg_stat_activity WHERE pid=$1)", [backend]).rows ==
                  [[true]]
              end)

              send(worker, :finish)
              assert_receive {:effect_result, {:error, :storage_unavailable}}, 15_000
            end

            assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 15_000
            eventually(fn -> WriteAdmission.status(server).phase == :recovery_required end)
            assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(server)
            GenServer.stop(server)
            {:ok, restarted} = WriteAdmission.start_link(Keyword.put(options, :initialize, false))

            try do
              assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(restarted)
              assert File.read!(Media.file_path(file_key)) == "escaped-effect"
            after
              GenServer.stop(restarted)
            end

            exact(request)
          end)
        end
    end
  end
end
