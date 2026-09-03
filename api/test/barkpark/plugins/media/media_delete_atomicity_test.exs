defmodule Barkpark.Plugins.Media.MediaDeleteAtomicityTest do
  @moduledoc """
  task-57ee9fff4aae9217 #12 — `Media.delete_file/2` must remove the blob row
  AND its companion `mediaAsset` document, in ONE transaction.

  ## What was actually broken (the row's own words are half the story)

  The triage addendum says the document "is read and never removed". Read
  against origin/main that is not literally true, and the difference is the
  whole bug: the document delete existed, but ONLY down the
  `after_media_delete` PLUGIN callback, and every link in that chain discarded
  its result —

    * `Registry.run_after_media_delete/1` walks the ENABLED plugin list, so
      with the media plugin absent from the resolver chain NOTHING deletes the
      document, and `delete_file/2` still answers `{:ok, _}`;
    * `Barkpark.Plugins.Media.after_media_delete/1` threw away
      `Assets.delete_for_blob/3`'s return and hard-coded `:ok`;
    * `Assets.delete_for_blob/3` threw away every `Content.delete_document/4`
      return with `_ =`, so a `rev_mismatch` or a halted `before_delete`
      produced a "successful" DELETE over a document that is still there.

  Those are the two arms below. Both RED on origin/main, and both RED for the
  same reason a customer saw: the API answered ok, and 517 drafts stayed.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Media.Assets

  @dataset "production"

  # ── plugin-list fixtures ──────────────────────────────────────────────────
  #
  # `ResolverChain.load_ordered_plugins/0` resolves the `:barkpark, :plugins`
  # list by NAME against `Registry.all/0`. A module the registry does not know
  # resolves to nothing, so configuring EITHER module below leaves
  # `run_after_media_delete/1` iterating an EMPTY list — the media plugin's
  # callback does not run. `Barkpark.Plugins.Hooks`, by contrast, reads the
  # configured list DIRECTLY, so `HaltAssetDelete`'s `before_delete` DOES fire.
  #
  # That split is exactly the isolation these two tests need: the setup below
  # registers the media plugin so the `mediaAsset` document is created at
  # UPLOAD time, and only the DELETE runs hook-free.

  defmodule NoPluginHooks do
    @moduledoc false
    def lifecycle_hooks, do: %{}
  end

  defmodule HaltAssetDelete do
    @moduledoc false

    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.halt/1]}

    # Stands in for the real-world refusals `Content.delete_document/4` can
    # return — a `before_delete` halt, or the `rev_mismatch` rollback a
    # concurrently-edited draft produces. Both reach `delete_for_blob/3` as
    # `{:error, _}`, which is the shape under test.
    def halt(%{doc: %{type: "mediaAsset"}}), do: {:halt, "asset locked by test"}
    def halt(_payload), do: :ok
  end

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} = Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})

    Barkpark.Plugins.Media.Codelists.seed_all()
    :ok
  end

  describe "delete_file/2 removes the mediaAsset document" do
    test "with NO after_media_delete plugin callback in the chain", ctx do
      file = upload!("dangling.png")
      assert Assets.find_by_media_file_id(file.id, @dataset)

      # From here on the media plugin's delete callback is out of the chain.
      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _deleted} = Media.delete_file(file.id)

      refute Assets.find_by_media_file_id(file.id, @dataset),
             "the mediaAsset document survived the blob delete while the API answered {:ok, _} " <>
               "— this is the shape that left Gyldendal 517 dangling drafts"

      assert {:error, :not_found} = Media.get_file(file.id)
    end

    test "a re-issued delete stays idempotent (:not_found on the doc is not a failure)", ctx do
      file = upload!("idem.png")
      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _} = Media.delete_file(file.id)
      assert {:error, :not_found} = Media.delete_file(file.id)
    end

    test "a blob with NO companion document deletes exactly as before", ctx do
      file = upload!("bare.png")
      :ok = Assets.delete_for_blob(file.id, @dataset)
      refute Assets.find_by_media_file_id(file.id, @dataset)

      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _} = Media.delete_file(file.id)
    end
  end

  describe "delete_file/2 is ATOMIC when the document delete fails" do
    test "the row comes back with the document, and the caller is told", ctx do
      file = upload!("locked.png")
      assert Assets.find_by_media_file_id(file.id, @dataset)

      :ok = Barkpark.PluginEnv.with_plugins([HaltAssetDelete], ctx)

      result = Media.delete_file(file.id)

      assert {:error, {:asset_doc_delete_failed, _reason}} = result,
             "delete_file/2 reported #{inspect(result)} while the mediaAsset document " <>
               "refused to delete — an ok over a surviving document is the bug"

      # BOTH halves survived. That is the point of "atomic": the blob row is
      # not allowed to outlive its document, and it is not allowed to die
      # without it either.
      assert {:ok, _} = Media.get_file(file.id),
             "the blob row was deleted even though its mediaAsset document survived"

      assert Assets.find_by_media_file_id(file.id, @dataset)
    end
  end

  describe "the resolve-before-delete ORDERING is preserved" do
    # A STRUCTURAL PIN. The triage addendum makes the ordering a CONSTRAINT on
    # this change ("your document delete must join the same transaction WITHOUT
    # moving that resolve above it"), because the `media.deleted` webhook
    # payload is resolved from a document that must still exist when the delete
    # begins, and the DB delete must stay the FIRST side effect. Nothing else in
    # the suite would notice the resolve sliding below the transaction — the
    # payload would silently become nil and every assertion would stay green.
    #
    # It also reds on origin/main, for the uninteresting reason that main has no
    # direct `delete_asset_doc/1` call to order anything against. The arm that
    # carries the constraint is `resolve_at < row_delete_at`.
    test "asset_doc_for_file/2 still runs before the delete transaction opens" do
      body = delete_file_source!()

      resolve_at = index_of!(body, "doc = asset_doc_for_file(file, file.dataset)")
      txn_at = index_of!(body, "Repo.transaction(")
      doc_delete_at = index_of!(body, "delete_asset_doc(file)")
      row_delete_at = index_of!(body, "Repo.delete(file, stale_error_field: :id)")

      assert resolve_at < txn_at,
             "the webhook payload resolve moved INSIDE/below the delete transaction"

      assert resolve_at < row_delete_at
      assert resolve_at < doc_delete_at
      assert row_delete_at < doc_delete_at
    end
  end

  defp delete_file_source! do
    source = File.read!(Path.join(__DIR__, "../../../../lib/barkpark/media.ex"))

    [_head, tail] = String.split(source, "def delete_file(id, opts \\\\ []) do", parts: 2)
    [body, _rest] = String.split(tail, "# \u2500\u2500 Deferred media-delete effects", parts: 2)
    body
  end

  defp index_of!(body, needle) do
    case :binary.match(body, needle) do
      {at, _len} -> at
      :nomatch -> flunk("`#{needle}` is no longer present in delete_file/2's body")
    end
  end

  defp upload!(name) do
    path = Path.join(System.tmp_dir!(), "media-del-#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: path, filename: name, content_type: "image/png"},
        @dataset
      )

    file
  end
end
