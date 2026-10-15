defmodule Barkpark.Media.Storage.LocalWriteTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.ManagedRuntime.WriteAdmission
  alias Barkpark.Media
  alias Barkpark.Media.Blobstore.Local
  alias Barkpark.Media.Storage.LocalWrite

  setup do
    previous = Application.get_env(:barkpark, :write_admission)
    instance = "local-write-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), instance)
    File.mkdir_p!(root)

    {:ok, gate} =
      WriteAdmission.start_link(
        journal: Path.join(root, "journal.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate, root: root}
  end

  test "prepared and logically deleted keys refuse byte, copy and delete effects before I/O",
       ctx do
    for state <- ["prepared", "pending_cleanup"] do
      key = key(state)
      original = "original-#{state}"
      assert {:ok, %{stored: size}} = Local.put_bytes(key, original, [])
      assert size == byte_size(original)
      pending(key, state)
      source = Path.join(ctx.root, "copy-#{state}")
      File.write!(source, "replacement")

      for alias_key <- [key, String.upcase(key)] do
        assert {:error, :storage_unavailable} = Local.put_bytes(alias_key, "replacement", [])
        assert {:error, :storage_unavailable} = Local.put_file(alias_key, source, [])
        assert {:error, :storage_unavailable} = Local.delete(alias_key)
      end

      assert File.read!(Media.file_path(key)) == original
      assert File.read!(source) == "replacement"
    end

    assert %{phase: :open, pending: 0} = WriteAdmission.status(ctx.gate)
  end

  test "unsupported aliases cannot bypass a pending key; unrelated ASCII writes remain usable",
       ctx do
    key = key("alias")
    assert {:ok, _} = Local.put_bytes(key, "retained", [])
    pending(key, "pending_cleanup")

    for alias_key <- [
          String.replace(key, "/", "\\"),
          key <> ".",
          key <> " ",
          "../" <> key,
          "2026/SHORTN~1.PNG",
          "2026/CONOUT$",
          "2026/file.bin:stream",
          "2026/Chø-note.png"
        ] do
      assert {:error, :storage_unavailable} = Local.put_bytes(alias_key, "replacement", [])
    end

    assert File.read!(Media.file_path(key)) == "retained"
    unrelated = key("unrelated")
    assert {:ok, %{stored: 5}} = Local.put_bytes(unrelated, "other", [])
    assert File.read!(Media.file_path(unrelated)) == "other"
    assert %{phase: :open, pending: 0} = WriteAdmission.status(ctx.gate)
  end

  test "ordinary Unicode media writes remain supported without unresolved cleanup" do
    key = key("Chø-箋")
    assert {:ok, %{stored: 7}} = Local.put_bytes(key, "unicode", [])
    assert File.read!(Media.file_path(key)) == "unicode"
  end

  test "managed delete failure retains uncertainty; ordinary delete preserves its contract",
       ctx do
    key = key("directory")
    File.mkdir_p!(Media.file_path(key))
    assert {:error, :storage_unavailable} = Local.delete(key)
    assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(ctx.gate)
    Application.delete_env(:barkpark, :write_admission)
    assert :ok = Local.delete(key)
    assert File.dir?(Media.file_path(key))
  end

  test "unknown retained operations refuse mutation, and rollback restores availability", ctx do
    key = key("rollback")
    assert {:ok, _} = Local.put_bytes(key, "old", [])

    assert {:error, :rollback_fixture} =
             Repo.transaction(fn ->
               Repo.query!(
                 "INSERT INTO media_delete_operations_v1(operation_id,media_id,state,request,raw_row) VALUES(gen_random_uuid(),gen_random_uuid(),'prepared','{}','{}')"
               )

               assert {:error, :storage_unavailable} = Local.put_bytes(key, "new", [])
               assert File.read!(Media.file_path(key)) == "old"
               Repo.rollback(:rollback_fixture)
             end)

    assert {:ok, %{stored: 3}} = Local.put_bytes(key, "new", [])
    assert File.read!(Media.file_path(key)) == "new"
    assert %{phase: :open, pending: 0} = WriteAdmission.status(ctx.gate)
  end

  test "an error after I/O begins retains physical uncertainty", ctx do
    assert {:error, :storage_unavailable} =
             LocalWrite.run(key("failed"), fn -> {:error, :storage_unavailable} end)

    assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(ctx.gate)
    refute WriteAdmission.status(ctx.gate).writers == 0
  end

  test "unverified receipts cannot be reported settled", ctx do
    assert {:ok, %{stored: :unverified}} =
             LocalWrite.run(key("unverified"), fn -> {:ok, %{stored: :unverified}} end)

    assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(ctx.gate)
  end

  test "a raised effect propagates and retains its pending root", ctx do
    assert_raise RuntimeError, "controlled effect failure", fn ->
      LocalWrite.run(key("raised"), fn -> raise "controlled effect failure" end)
    end

    assert %{phase: :recovery_required, pending: 1} = WriteAdmission.status(ctx.gate)
  end

  test "database refusal before I/O releases the unused effect admission", ctx do
    Repo.query!("ALTER TABLE media_delete_operations_v1 RENAME TO local_write_missing_fixture")
    parent = self()

    assert {:error, :storage_unavailable} =
             LocalWrite.run(key("database"), fn ->
               send(parent, :unexpected_effect)
               :ok
             end)

    refute_received :unexpected_effect
    assert %{phase: :open, pending: 0} = WriteAdmission.status(ctx.gate)
  end

  test "missing enabled coordinator refuses before its callback", ctx do
    Application.put_env(:barkpark, :write_admission,
      enabled: true,
      instance_id: "missing-#{ctx.root}"
    )

    refute_received :unexpected_effect
    parent = self()

    assert {:error, :storage_unavailable} =
             LocalWrite.run(key("missing"), fn ->
               send(parent, :unexpected_effect)
               :ok
             end)

    refute_received :unexpected_effect
  end

  test "an ordinary server does not acquire managed admission or inspect pending operations" do
    Application.delete_env(:barkpark, :write_admission)
    key = key("ordinary")
    pending(key, "pending_cleanup")
    assert {:ok, %{stored: 8}} = Local.put_bytes(key, "ordinary", [])
    assert File.read!(Media.file_path(key)) == "ordinary"
  end

  defp pending(key, state) do
    Repo.query!(
      "INSERT INTO media_delete_operations_v1(operation_id,media_id,state,request,raw_row) VALUES(gen_random_uuid(),gen_random_uuid(),$1,$2::jsonb,'{}')",
      [state, %{"expectedKey" => key}]
    )
  end

  defp key(suffix), do: "test/local-write/#{System.unique_integer([:positive])}/#{suffix}.bin"
end
