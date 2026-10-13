defmodule Barkpark.Media.PendingDeleteBoundaryTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle.Catalog
  alias Barkpark.Tenancy.WorkspaceBundle

  test "ordinary absolute and Unicode media addresses retain reservation ownership" do
    for address <- ["/media/legacy.png", "2026/Chø-note.png"] do
      id = insert_media(address)

      assert %{rows: [[^id]]} =
               Repo.query!(
                 "SELECT media_ids[1]::text FROM media_object_reservations_v1 WHERE address=public.media_object_address_v1($1)",
                 [address]
               )

      Repo.query!("DELETE FROM media_files WHERE id=$1::uuid", [uuid_binary(id)])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM media_object_reservations_v1 WHERE $1::uuid=ANY(media_ids)",
                 [uuid_binary(id)]
               )
    end
  end

  test "current media schema preserves SHA-1 in intent and refuses case-alias reuse" do
    key = "2026/pending-#{System.unique_integer([:positive])}.png"
    id = insert_media(key)
    operation = Ecto.UUID.generate()
    request = request(id, operation, key)

    assert %{rows: [[prepared]]} =
             Repo.query!("SELECT prepare_media_delete_v1($1::jsonb)", [request])

    assert prepared["rawRow"]["sha1"] == String.duplicate("a", 40)
    assert prepared["state"] == "prepared"

    Repo.query!(
      "UPDATE media_object_reservations_v1 SET operation_id=$1::uuid WHERE media_ids=ARRAY[$2::uuid]",
      [uuid_binary(operation), uuid_binary(id)]
    )

    Repo.query!("DELETE FROM media_files WHERE id=$1::uuid", [uuid_binary(id)])

    assert %{rows: [[^id]]} =
             Repo.query!(
               "SELECT media_ids[1]::text FROM media_object_reservations_v1 WHERE operation_id=$1::uuid",
               [uuid_binary(operation)]
             )

    assert_raise Postgrex.Error, ~r/media object address is reserved/, fn ->
      insert_media(String.upcase(key))
    end
  end

  test "ordinary co-owners survive until individually deleted" do
    key = "2026/shared-#{System.unique_integer([:positive])}.png"
    first = insert_media(key)
    second = insert_media(key)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT cardinality(media_ids) FROM media_object_reservations_v1 WHERE address=public.media_object_address_v1($1)",
               [key]
             )

    Repo.query!("DELETE FROM media_files WHERE id=$1::uuid", [uuid_binary(first)])

    assert %{rows: [[^second]]} =
             Repo.query!(
               "SELECT media_ids[1]::text FROM media_object_reservations_v1 WHERE address=public.media_object_address_v1($1)",
               [key]
             )
  end

  test "pending host-local cleanup refuses both bundle paths instead of disappearing" do
    assert :ok = Catalog.assert_partition!(Repo)
    assert :ok = Catalog.assert_dev_partition!(Repo)

    Repo.query!(
      "INSERT INTO media_delete_operations_v1(operation_id,media_id,state,request,raw_row) VALUES(gen_random_uuid(),gen_random_uuid(),'prepared','{}','{}')",
      []
    )

    for assert_partition <- [&Catalog.assert_partition!/1, &Catalog.assert_dev_partition!/1] do
      assert_raise RuntimeError, ~r/pending host-local media cleanup must be reconciled/, fn ->
        assert_partition.(Repo)
      end
    end

    workspace = Barkpark.TenancyFixtures.create_workspace!()

    for profile <- [:full, :dev] do
      assert_raise RuntimeError, ~r/pending host-local media cleanup must be reconciled/, fn ->
        WorkspaceBundle.export(workspace.id, profile: profile)
      end
    end
  end

  # Synthetic database observations exercise schema/ownership contracts only.
  # Native identity and physical bytes are proven by the owned Windows runner.
  defp request(id, operation, key) do
    %{
      "version" => 1,
      "operationId" => operation,
      "mediaId" => id,
      "expectedKey" => key,
      "root" => %{"path" => "C:\\Owned\\Media", "device" => "1", "inode" => "2"},
      "file" => %{
        "bytes" => 1,
        "links" => 1,
        "device" => "1",
        "inode" => "3",
        "sha256" => String.duplicate("b", 64),
        "observedAt" => "2026-10-13T00:00:00.000Z"
      }
    }
  end

  defp insert_media(address) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO media_files(id,filename,original_name,path,object_key,mime_type,size,dataset,sha1,inserted_at,updated_at)
        VALUES(gen_random_uuid(),'fixture.png','fixture.png',$1,$1,'image/png',1,'production',$2,now(),now())
        RETURNING id::text
        """,
        [address, String.duplicate("a", 40)]
      )

    id
  end

  defp uuid_binary(id), do: Ecto.UUID.dump!(id)
end
