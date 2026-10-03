defmodule Barkpark.Content.DiscardDraftAfterDeleteTest do
  @moduledoc """
  Owner ruling #32 item 5 (2026-10-03): discarding a draft that was the
  document's ONLY row removes the document, so it fires the `:after_delete`
  plugin hook — the same post-commit `WriteScope.fire_after/3` the delete path
  uses. Before this, a draft-only document that was discarded never reached
  the Indx delete hook and an external index kept it.

  When a published row remains, the document still exists: no `:after_delete`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "discard_after_delete_test"
  @type_name "dpost"
  @spy :discard_after_delete_spy

  defmodule AfterDeleteSpyPlugin do
    @moduledoc false

    def manifest, do: %{"plugin_name" => "discard-after-delete-spy", "version" => "0.0.0"}

    def lifecycle_hooks, do: %{after_delete: [&__MODULE__.after_delete/1]}

    def after_delete(%{doc: doc, event: event}) do
      case Process.whereis(:discard_after_delete_spy) do
        nil -> :ok
        pid -> send(pid, {:after_delete, event, doc.doc_id})
      end

      :ok
    end
  end

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "DPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    Process.register(self(), @spy)

    :ok =
      Barkpark.Plugins.Registry.register(AfterDeleteSpyPlugin, AfterDeleteSpyPlugin.manifest())

    on_exit(fn -> Barkpark.Plugins.Registry.reset() end)
    :ok
  end

  defp draft!(id, title \\ "Title") do
    {:ok, _} = Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)
    :ok
  end

  defp drain_after_deletes(acc \\ []) do
    receive do
      {:after_delete, _event, _doc_id} = msg -> drain_after_deletes([msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "discarding a draft-only document fires :after_delete exactly once" do
    draft!("only-draft")

    assert {:ok, _} = Content.discard_draft("only-draft", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("only-draft", @type_name, @dataset)

    assert [{:after_delete, :after_delete, "drafts.only-draft"}] = drain_after_deletes()
  end

  test "discarding a draft whose published twin remains fires no :after_delete" do
    draft!("has-pub")
    {:ok, _} = Content.publish_document("has-pub", @type_name, @dataset)
    draft!("has-pub", "Edited")

    assert {:ok, _} = Content.discard_draft("has-pub", @type_name, @dataset)
    assert {:ok, _} = Content.get_document("has-pub", @type_name, @dataset)

    assert [] = drain_after_deletes()
  end

  test "a discard that finds no draft fires nothing" do
    assert {:error, :not_found} = Content.discard_draft("never-was", @type_name, @dataset)
    assert [] = drain_after_deletes()
  end

  test "delete_document still fires :after_delete exactly once" do
    draft!("plain-del")
    {:ok, _} = Content.publish_document("plain-del", @type_name, @dataset)
    draft!("plain-del", "Edited")

    assert {:ok, _} = Content.delete_document("plain-del", @type_name, @dataset)
    assert [{:after_delete, :after_delete, "plain-del"}] = drain_after_deletes()
  end
end
