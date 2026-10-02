defmodule Barkpark.ManagedRuntime.WriteAdmission.DoorsSlice2Test do
  # Slice 2 of Barkdown C083: a held managed instance refuses native Paper block
  # ops, media upload/blob/delete/processing, and serves a stale HTML cache
  # without persisting the repair. Not async: it enables write admission for the
  # whole VM while it runs.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "test"

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-admission-s2-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "s2-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
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

  defp refused, do: {:error, {:write_admission, :admission_closed}}

  test "block ops doors refuse while held and admit while open", %{gate: gate} do
    slug = "s2-paper-#{System.unique_integer([:positive])}"
    block = %{"id" => "p1", "type" => "paragraph", "text" => "first"}
    attrs = Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: [block]})
    assert {:ok, created} = Content.upsert_paper(attrs)
    ds = created.dataset
    before = Content.get_paper(slug, ds)
    assert Admission.status(gate).pending == 0

    hold = hold(gate, "switch")

    op = %{
      "op" => "append-block",
      "block" => %{"id" => "p2", "type" => "paragraph", "text" => "x"}
    }

    assert refused() == Content.upsert_paper(attrs)
    assert refused() == Papers.BlockOps.apply_paper_block_op(slug, op, ds, [])
    assert refused() == Papers.BlockOps.apply_paper_block_ops(slug, [op], ds, [])

    assert refused() ==
             Papers.BlockOps.apply_paper_block_ops_once(slug, [op], ds, "req-1", "pk", [])

    assert refused() == Papers.BlockOps.apply_document_block_op("drafts.x", "post", op, ds)

    assert refused() ==
             Papers.BlockOps.apply_field_block_ops("drafts.x", "post", "body", [op], ds)

    after_hold = Content.get_paper(slug, ds)
    assert after_hold.rev == before.rev
    assert after_hold.content == before.content
    assert Admission.status(gate).phase == :held
    release(gate, hold)

    assert {:ok, _} = Content.upsert_paper(attrs)
    assert Admission.status(gate).pending == 0
  end

  test "a stale HTML cache is served without being persisted while held", %{gate: gate} do
    slug = "s2-cache-#{System.unique_integer([:positive])}"
    block = %{"id" => "p1", "type" => "paragraph", "text" => "cached"}

    assert {:ok, created} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: [block]})
             )

    ds = created.dataset

    paper = Content.get_paper(slug, ds)
    stale = Map.merge(paper.content, %{"body_html" => "<p>stale</p>", "body_html_sv" => "0"})

    {1, _} =
      from(d in Content.Document, where: d.id == ^paper.id)
      |> Repo.update_all(set: [content: stale])

    paper = Content.get_paper(slug, ds)
    assert get_in(paper.content, ["body_html"]) == "<p>stale</p>"

    hold = hold(gate, "switch")
    assert {:blocks, blocks} = Papers.reader_source(paper, ds, [])
    assert [%{"text" => "cached"} | _] = blocks
    unchanged = Content.get_paper(slug, ds)
    assert unchanged.rev == paper.rev
    assert get_in(unchanged.content, ["body_html"]) == "<p>stale</p>"
    assert Admission.status(gate).phase == :held
    release(gate, hold)

    # Control: the same read repairs the cache once admission is open again.
    assert {:blocks, _} = Papers.reader_source(paper, ds, [])
    repaired = Content.get_paper(slug, ds)
    refute get_in(repaired.content, ["body_html"]) == "<p>stale</p>"
    assert Admission.status(gate).pending == 0
  end

  test "media doors refuse while held and leave rows and bytes unchanged", %{gate: gate} do
    row = insert_media_row!()
    rows = Repo.aggregate(MediaFile, :count)
    upload_dir = Media.upload_dir()
    File.mkdir_p!(upload_dir)
    files_before = File.ls!(upload_dir) |> Enum.sort()

    tmp = Path.join(System.tmp_dir!(), "s2-upload-#{System.unique_integer([:positive])}.bin")
    File.write!(tmp, "bytes")
    upload = %Plug.Upload{path: tmp, filename: "s2.bin", content_type: "application/octet-stream"}

    hold = hold(gate, "switch")
    assert refused() == Media.upload(upload, @dataset, [])
    assert refused() == Media.put_blob("s2/blob.bin", "bytes", [])
    assert refused() == Media.delete_file(row.id, dataset: @dataset)
    assert refused() == Media.Processing.process(row)

    assert Repo.aggregate(MediaFile, :count) == rows
    assert Repo.get(MediaFile, row.id)
    assert File.ls!(upload_dir) |> Enum.sort() == files_before
    assert Admission.status(gate).phase == :held
    release(gate, hold)
    assert Admission.status(gate).pending == 0
  end

  defp insert_media_row! do
    suffix = System.unique_integer([:positive])

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: "s2-#{suffix}.png",
      original_name: "s2-#{suffix}.png",
      path: "test/s2/#{suffix}.png",
      mime_type: "image/png",
      size: 42,
      dataset: @dataset
    })
    |> Repo.insert!()
  end

  # The test process owns the hold: begin_hold/reopen are synchronous calls that
  # journal to DETS before replying, so there is no message to race. A spawned
  # holder re-published the replies against assert_receive's 100ms default,
  # which CI load outran (main run 36574063509, task-5381a4e7a1724185). The
  # owner only needs to hold no write of its own when the hold begins.
  defp hold(gate, operation) do
    assert {:ok, :held, ticket} =
             Admission.begin_hold(gate, operation, Admission.status(gate).generation)

    ticket
  end

  defp release(gate, ticket), do: assert(Admission.reopen(gate, ticket) == :ok)
end
