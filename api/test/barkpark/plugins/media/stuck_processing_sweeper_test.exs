defmodule Barkpark.Plugins.Media.StuckProcessingSweeperTest do
  @moduledoc """
  Proves the media reconciliation sweeper terminates and heals.

  Two mutation-grade proofs anchor the suite:

    * TERMINATION — a row whose re-drive RAISES every time (a corrupt-image
      stand-in) is bumped past the attempt ceiling and written terminal
      `"failed"`. The row is then backdated AGAIN so its `updated_at` is old:
      the only thing that can remove it from the candidate SELECT is the status
      filter. If give-up wrote `"processing"` instead of `"failed"`, the final
      sweep would re-select and re-give-up (swept: 1) instead of finding nothing
      — the assertion reds. This is the crown invariant: give-up self-removes.

    * RECOVERY — a row stranded at `"processing"` is re-driven by the REAL
      idempotent `Processing.process/1` to a terminal `"ready"` and no longer
      selected. Without the re-drive it would stay `"processing"` forever.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Plugins.Media.StuckProcessingSweeper
  alias Barkpark.Repo

  @dataset "production"
  @asset_type "mediaAsset"

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} = Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})
    Barkpark.Plugins.Media.Codelists.seed_all()

    prev_after = Application.get_env(:barkpark, :media_stuck_processing_after_seconds)
    prev_max = Application.get_env(:barkpark, :media_stuck_processing_max_attempts)
    prev_fun = Application.get_env(:barkpark, :media_stuck_reprocess_fun)
    prev_batch = Application.get_env(:barkpark, :media_stuck_processing_batch_limit)

    on_exit(fn ->
      set_or_delete(:media_stuck_processing_after_seconds, prev_after)
      set_or_delete(:media_stuck_processing_max_attempts, prev_max)
      set_or_delete(:media_stuck_reprocess_fun, prev_fun)
      set_or_delete(:media_stuck_processing_batch_limit, prev_batch)
    end)

    :ok
  end

  describe "sweep/1 — empty and poison-row isolation" do
    test "empty candidate set returns zeroes and never raises" do
      assert %{swept: 0, skipped: 0} = StuckProcessingSweeper.sweep(0)
    end

    test "one poison row never aborts the batch — every candidate is attempted" do
      # Two stranded rows whose re-drive RAISES. A naive reduce would let the
      # first raise abort the whole batch (second row starved). With per-row
      # try/rescue both are attempted and counted skipped.
      Application.put_env(:barkpark, :media_stuck_reprocess_fun, fn _file ->
        raise "backend port crash (simulated)"
      end)

      file_a = stranded_asset!()
      file_b = stranded_asset!()

      assert %{swept: 0, skipped: 2} = StuckProcessingSweeper.sweep(0)

      # Both survive as `processing` (rescue left them for the next tick), each
      # with a bumped attempt counter.
      assert status(file_a) == "processing"
      assert status(file_b) == "processing"
      assert attempts(file_a) == 1
      assert attempts(file_b) == 1
    end
  end

  describe "TERMINATION — give-up self-removes from the candidate SELECT" do
    test "a forever-raising row is written terminal 'failed' and no longer selected" do
      Application.put_env(:barkpark, :media_stuck_processing_max_attempts, 2)

      Application.put_env(:barkpark, :media_stuck_reprocess_fun, fn _file ->
        raise "deterministic decode failure (corrupt image)"
      end)

      file = stranded_asset!()

      # Tick 1: attempts 0 < 2 → bump to 1, re-drive raises → skipped.
      backdate!(file)
      assert %{swept: 0, skipped: 1} = StuckProcessingSweeper.sweep(0)
      assert status(file) == "processing"
      assert attempts(file) == 1

      # Tick 2: attempts 1 < 2 → bump to 2, re-drive raises → skipped.
      backdate!(file)
      assert %{swept: 0, skipped: 1} = StuckProcessingSweeper.sweep(0)
      assert status(file) == "processing"
      assert attempts(file) == 2

      # Tick 3: attempts 2 ≥ 2 → GIVE UP, write terminal "failed" (swept).
      backdate!(file)
      assert %{swept: 1, skipped: 0} = StuckProcessingSweeper.sweep(0)
      assert status(file) == "failed"

      # Backdate AFTER the give-up write so `updated_at` is old again: the ONLY
      # thing that can now keep this row out of the candidate SELECT is the
      # status filter. If give-up had written "processing", this sweep would
      # re-select and re-give-up (swept: 1) — the zeroes assertion reds.
      backdate!(file)
      assert %{swept: 0, skipped: 0} = StuckProcessingSweeper.sweep(0)
      assert status(file) == "failed"
    end
  end

  describe "RECOVERY — a stranded row is re-driven to a terminal state" do
    test "real Processing.process heals a 'processing' row to 'ready'; then unselected" do
      # No reprocess_fun override → the sweeper uses the real, idempotent
      # Processing.process/1. A non-raster asset (PDF) has no renditions to make,
      # so process drives it straight to a terminal "ready".
      file = stranded_asset!(content_type: "application/pdf")
      assert status(file) == "processing"

      backdate!(file)
      assert %{swept: 1, skipped: 0} = StuckProcessingSweeper.sweep(0)
      assert status(file) == "ready"

      # Terminal now → excluded from the SELECT even with an old updated_at.
      backdate!(file)
      assert %{swept: 0, skipped: 0} = StuckProcessingSweeper.sweep(0)
    end

    test "a deleted parent blob (get_file not_found) is skipped as a no-op" do
      # A stranded asset doc whose mediaFileId points at no media_files row —
      # the parent blob was deleted out from under it.
      doc_id = "asset-orphan-#{System.unique_integer([:positive])}"

      {:ok, _doc} =
        %Document{}
        |> Document.changeset(%{
          doc_id: doc_id,
          type: @asset_type,
          dataset: @dataset,
          title: "orphan",
          status: "draft",
          rev: "r0",
          content: %{
            "mediaFileId" => Ecto.UUID.generate(),
            "bp_processing_status" => "processing"
          }
        })
        |> Repo.insert()

      backdate_doc!(doc_id)

      assert %{swept: 0, skipped: 1} = StuckProcessingSweeper.sweep(0)
      # Untouched — no terminal write, no counter bump.
      assert doc_status(doc_id) == "processing"
    end
  end

  describe "Oban wiring" do
    test "perform/1 runs the sweep and returns {:ok, tally}" do
      assert {:ok, %{swept: 0, skipped: 0}} =
               StuckProcessingSweeper.perform(%Oban.Job{args: %{}})
    end

    test "media plugin registers the per-minute cron on the :default queue" do
      assert Barkpark.Plugins.Media.oban_crontab() == [
               {"* * * * *", Barkpark.Plugins.Media.StuckProcessingSweeper}
             ]
    end

    # FRESH-INSTALL INVARIANT (plugin_free_boot_test tier 5's runtime twin).
    # The sweeper is PLUGIN code, reached only through the plugin's
    # `oban_crontab/0` collector — never through the host's static
    # `config.exs` :crontab. So with `:plugins []` the cron entry the host
    # folds into Oban at boot must not name it AT ALL: no worker is
    # registered, nothing sweeps, and `lib/barkpark/plugins/media/` can be
    # deleted wholesale without stranding a cron pointing at a gone module.
    # Moving this entry to config.exs (or the module back to host code) reds
    # here.
    test "a plugin-free boot registers NO sweeper cron entry" do
      prev = Application.get_env(:barkpark, :plugins, :unset)

      on_exit(fn ->
        case prev do
          :unset -> Application.delete_env(:barkpark, :plugins)
          v -> Application.put_env(:barkpark, :plugins, v)
        end
      end)

      # Sanity arm: with Media loaded the entry IS collected — so the
      # plugins-off arm below is a real absence, not a vacuous one.
      Application.put_env(:barkpark, :plugins, [Barkpark.Plugins.Media])

      assert {"* * * * *", StuckProcessingSweeper} in Barkpark.Plugins.Registry.collect_oban_crontab()

      Application.put_env(:barkpark, :plugins, [])

      crontab = Barkpark.Plugins.Registry.collect_oban_crontab()

      refute Enum.any?(crontab, fn
               {_expr, worker} -> worker == StuckProcessingSweeper
               {_expr, worker, _opts} -> worker == StuckProcessingSweeper
               _ -> false
             end)

      # And the host's own static Oban config never names it either — the
      # only path to this worker is the plugin collector.
      static_crontab =
        :barkpark
        |> Application.fetch_env!(Oban)
        |> Keyword.get(:plugins, [])
        |> Enum.find_value([], fn
          {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
          _ -> nil
        end)

      refute Enum.any?(static_crontab, fn entry ->
               elem(entry, 1) == StuckProcessingSweeper
             end)
    end
  end

  # ---- helpers ----------------------------------------------------------------

  # Upload a real blob, ensure its companion mediaAsset doc, then force it into
  # the stranded `processing` state (no attempts counter). Returns the MediaFile.
  defp stranded_asset!(opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/pdf")
    ext = if content_type == "application/pdf", do: "pdf", else: "bin"
    name = "stuck-#{System.unique_integer([:positive])}.#{ext}"
    temp = write_temp!(name, "fake #{content_type} bytes")

    {:ok, file} =
      Media.upload(%Plug.Upload{path: temp, filename: name, content_type: content_type}, @dataset)

    {:ok, doc} = Assets.ensure_for_upload(file)

    content =
      (doc.content || %{})
      |> Map.put("bp_processing_status", "processing")
      |> Map.delete("bp_processing_attempts")

    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^doc.doc_id and d.type == ^@asset_type),
        set: [content: content]
      )

    file
  end

  # Push the asset doc's updated_at an hour into the past so it clears the cutoff.
  defp backdate!(file) do
    doc = Assets.find_by_media_file_id(file.id, @dataset)
    backdate_doc!(doc.doc_id)
  end

  defp backdate_doc!(doc_id) do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second)

    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^doc_id and d.type == ^@asset_type),
        set: [updated_at: past]
      )

    :ok
  end

  defp status(file) do
    doc = Assets.find_by_media_file_id(file.id, @dataset)
    Map.get(doc.content || %{}, "bp_processing_status")
  end

  defp attempts(file) do
    doc = Assets.find_by_media_file_id(file.id, @dataset)
    Map.get(doc.content || %{}, "bp_processing_attempts")
  end

  defp doc_status(doc_id) do
    doc = Repo.one(from d in Document, where: d.doc_id == ^doc_id and d.type == ^@asset_type)
    Map.get(doc.content || %{}, "bp_processing_status")
  end

  defp write_temp!(name, body) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, body)
    path
  end

  defp set_or_delete(key, nil), do: Application.delete_env(:barkpark, key)
  defp set_or_delete(key, val), do: Application.put_env(:barkpark, key, val)
end
