defmodule Barkpark.Plugins.Media.MediaDeleteAtomicityTest do
  @moduledoc """
  task-1116dcb208496fc7 — `Media.delete_file/2` must remove the blob row AND its
  companion `mediaAsset` document, together, and must never answer with an
  unmatched `{:error, :rollback}`.

  The BEGIN-time half of the #15827 incident (`mode: :savepoint` on an `:idle`
  connection) lives in `media_delete_savepoint_reproduction_test.exs`; it cannot
  be seen from a sandboxed test body. THIS module carries the behaviour that
  survives inside the sandbox:

    * the document really goes with the row, with the plugin hook OUT of the
      chain (the 517-dangling-drafts shape);
    * BOTH fixtures — a draft-only asset doc and a published+draft pair;
    * a refused document delete rolls the ROW back and reports a NAMED reason;
    * a nested `Repo.rollback` that poisons our transaction WITHOUT giving us a
      reason still comes out named, not as `{:error, :rollback}`;
    * the stale/concurrent-delete 404 arm;
    * the resolve-before-delete ordering.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
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
  # configured list DIRECTLY, so the `before_delete` callbacks below DO fire.
  #
  # That split is exactly the isolation these tests need: the setup registers
  # the media plugin so the `mediaAsset` document is created at UPLOAD time, and
  # only the DELETE runs hook-free.

  defmodule NoPluginHooks do
    @moduledoc false
    def lifecycle_hooks, do: %{}
  end

  defmodule HaltAssetDelete do
    @moduledoc false

    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.halt/1]}

    # Stands in for the real refusals `Content.delete_document/4` returns — a
    # `before_delete` halt, or the `rev_mismatch` a concurrently-edited draft
    # produces. Both reach `delete_for_blob/3` as `{:error, _}`.
    def halt(%{doc: %{type: "mediaAsset"}}), do: {:halt, "asset locked by test"}
    def halt(_payload), do: :ok
  end

  defmodule VanishAssetDocRows do
    @moduledoc false

    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.vanish/1]}

    # THE NESTED-ROLLBACK ARM. `Content.Lifecycle.do_delete_document/4` reads
    # the published+draft variants, fires `:before_delete`, and only THEN opens
    # its own `Repo.transaction`. Deleting the rows out from under it here makes
    # every `fenced_delete/1` inside that transaction answer `:not_found`, so it
    # takes its `Repo.rollback(:not_found)` branch.
    #
    # That rollback is nested inside `Media.delete_file/2`'s transaction. Ecto
    # issues NO savepoint for a nested `Repo.transaction` (DBConnection's
    # conn_mode: :transaction clause ignores `:mode`), so `DBConnection.fail/1`
    # marks the whole connection `:aborted`. `delete_for_blob/3` is handed a
    # tidy `{:error, :not_found}`, treats it as success — and our outer
    # transaction body then returns normally onto a poisoned connection, whose
    # `conclude/2` throws `:rollback`. `{:error, :rollback}` with NO reason
    # attached is the exact tuple that had no `case` clause in #15827.
    def vanish(%{doc: %{type: "mediaAsset", doc_id: doc_id}}) do
      base = String.replace_prefix(doc_id, "drafts.", "")

      Barkpark.Repo.delete_all(
        from(d in Barkpark.Content.Document,
          where: d.type == "mediaAsset" and d.doc_id in ^[base, "drafts." <> base]
        )
      )

      :ok
    end

    def vanish(_payload), do: :ok
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
    test "a DRAFT-ONLY asset doc goes with the row, with no plugin callback in the chain", ctx do
      file = upload!("dangling.png")
      assert %{status: "draft"} = Assets.find_by_media_file_id(file.id, @dataset)

      # From here on the media plugin's delete callback is out of the chain.
      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _deleted} = Media.delete_file(file.id, where_used: :cascade)

      refute Assets.find_by_media_file_id(file.id, @dataset),
             "the mediaAsset document survived the blob delete while the API answered {:ok, _} " <>
               "— this is the shape that left Gyldendal 517 dangling drafts"

      assert {:error, :not_found} = Media.get_file(file.id)
    end

    test "a PUBLISHED+DRAFT asset doc pair goes with the row — BOTH variants", ctx do
      file = upload!("published.png")
      doc = Assets.find_by_media_file_id(file.id, @dataset)
      published_id = String.replace_prefix(doc.doc_id, "drafts.", "")

      {:ok, _} = Content.publish_document(published_id, "mediaAsset", @dataset)

      assert doc_ids(file.id) != [],
             "fixture guard: the publish left no mediaAsset rows to delete"

      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _deleted} = Media.delete_file(file.id, where_used: :cascade)

      assert doc_ids(file.id) == [],
             "a mediaAsset variant survived the blob delete — the published+draft pair is " <>
               "the fixture the prod dataset actually holds"
    end

    test "a re-issued delete stays idempotent (:not_found on the doc is not a failure)", ctx do
      file = upload!("idem.png")
      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _} = Media.delete_file(file.id, where_used: :cascade)
      assert {:error, :not_found} = Media.delete_file(file.id, where_used: :cascade)
    end

    test "a blob with NO companion document deletes exactly as before", ctx do
      file = upload!("bare.png")
      :ok = Assets.delete_for_blob(file.id, @dataset)
      refute Assets.find_by_media_file_id(file.id, @dataset)

      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      assert {:ok, _} = Media.delete_file(file.id, where_used: :cascade)
    end
  end

  describe "delete_file/2 is ATOMIC when the document delete fails" do
    test "the row comes back with the document, and the caller is told WHY", ctx do
      file = upload!("locked.png")
      assert Assets.find_by_media_file_id(file.id, @dataset)

      :ok = Barkpark.PluginEnv.with_plugins([HaltAssetDelete], ctx)

      result = Media.delete_file(file.id, where_used: :cascade)

      assert match?({:error, {:asset_doc_delete_failed, {:halted, _}}}, result),
             "delete_file/2 reported #{inspect(result)} while the mediaAsset document " <>
               "refused to delete — an ok over a surviving document is the bug, and a bare " <>
               "{:error, :rollback} is the 500"

      # BOTH halves survived. That is the point of "atomic": the blob row is not
      # allowed to outlive its document, and it is not allowed to die without it
      # either.
      row_after = Media.get_file(file.id)

      assert match?({:ok, _}, row_after),
             "the blob row was deleted even though its mediaAsset document survived — got #{inspect(row_after)}"

      assert Assets.find_by_media_file_id(file.id, @dataset)
    end

    test "a NESTED Repo.rollback that reports no reason still comes out NAMED", ctx do
      file = upload!("poisoned.png")
      assert Assets.find_by_media_file_id(file.id, @dataset)

      :ok = Barkpark.PluginEnv.with_plugins([VanishAssetDocRows], ctx)

      result = Media.delete_file(file.id, where_used: :cascade)

      refute result == {:error, :rollback},
             "delete_file/2 leaked DBConnection's bare {:error, :rollback} — the exact tuple " <>
               "#15827's case had no clause for (CaseClauseError inside delete_file/2, HTTP 500)"

      assert match?({:error, {:asset_doc_delete_failed, _reason}}, result),
             "expected a NAMED asset-doc failure, got #{inspect(result)}"

      # The transaction was rolled back wholesale, so the blob row is still here.
      assert match?({:ok, _}, Media.get_file(file.id))
    end
  end

  describe "the stale / concurrent-delete arm is preserved" do
    test "a row consumed by a concurrent DELETE is {:error, :not_found}, not a 500", ctx do
      file = upload!("raced.png")
      :ok = Barkpark.PluginEnv.with_plugins([NoPluginHooks], ctx)

      # The concurrent claimant: the row is gone, but our caller still holds the
      # struct it read a moment ago. Repo.delete/2 must surface that as a stale
      # changeset (→ 404), never an uncaught Ecto.StaleEntryError.
      {:ok, stale_struct} = Media.get_file(file.id)
      {:ok, _} = Media.delete_file(file.id, where_used: :cascade)

      assert Barkpark.Media.delete_file(stale_struct.id, where_used: :cascade) ==
               {:error, :not_found}
    end
  end

  describe "the resolve-before-delete ORDERING is preserved" do
    # A STRUCTURAL PIN. The `media.deleted` webhook payload is resolved from a
    # document that must still exist when the delete begins, and the DB delete
    # must stay the FIRST side effect. Nothing else in the suite would notice
    # the resolve sliding below the transaction — the payload would silently
    # become nil and every assertion would stay green.
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

    # THE #15827 TRIPWIRE. `mode: :savepoint` is a no-op nested and a hard
    # BEGIN failure at the top level; see
    # `media_delete_savepoint_reproduction_test.exs` for the reproduction. The
    # sandbox cannot see it come back, so a source pin guards the re-entry.
    test "the delete transaction carries NO mode: :savepoint" do
      body = delete_file_source!()

      refute body =~ "mode: :savepoint",
             "mode: :savepoint is back in the media delete path. On an :idle connection " <>
               "Postgrex.Protocol.handle_begin/2 returns the status :idle, DBConnection raises " <>
               "%TransactionError{message: \"transaction is not started\"} and answers " <>
               "{:error, :rollback} — every prod DELETE 500s, and no sandboxed test can see it."
    end
  end

  defp doc_ids(media_file_id) do
    Barkpark.Repo.all(
      from(d in Barkpark.Content.Document,
        where:
          d.type == "mediaAsset" and
            fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id),
        select: d.doc_id
      )
    )
  end

  defp delete_file_source! do
    source = File.read!(Path.join(__DIR__, "../../../../lib/barkpark/media.ex"))

    [_head, tail] =
      String.split(source, "def delete_file(id, opts) when is_list(opts) do", parts: 2)

    [body, _rest] = String.split(tail, "# ── Deferred media-delete effects", parts: 2)
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
