defmodule BarkparkWeb.Studio.StudioLiveConcurrentEditTest do
  @moduledoc """
  Two Studio LiveView reliability guards (studio-concurrent-edit-and-id):

    1. CONCURRENT-EDIT lost update. When another user saves the open document
       while the local form buffer holds unsaved edits (`editor_dirty`), the
       `doc_updated` / `document_changed` handlers must NOT overwrite the buffer.
       They raise the `doc_conflict` banner instead and leave `editor_form`
       untouched. With NO unsaved edits, the in-place auto-refresh is preserved.

    2. NEW-DOC id collision-resistance. `new_document` must no longer mint a
       `:rand.uniform(999_999)` id (1M-value space → silent overwrite on a
       populated dataset). It omits `doc_id` and lets `Content.create_document`
       generate a `<type>-<64-bit-hex>` id; ids across many creates are distinct.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Handlers.{Fields, Lifecycle}

  @dataset "production"

  # A form-editor socket the lifecycle handlers accept. `editor_schema: nil`
  # keeps `Content.doc_to_form/2` to its base `%{"title","status"}` projection
  # so the assertions don't depend on a seeded schema.
  defp editor_socket(editor_dirty) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        editor_doc: %{doc_id: "p1", title: "Local Title", status: "draft"},
        editor_schema: nil,
        editor_form: %{"title" => "Local Title", "status" => "draft"},
        editor_dirty: editor_dirty,
        doc_conflict: false,
        save_status: ""
      }
    }
  end

  # A `{:doc_updated, msg}`-shaped payload from ANOTHER editor process. Spawning
  # a distinct pid makes `sender != self()` true (the self-write guard).
  defp remote_msg do
    other = spawn(fn -> :ok end)

    %{
      sender: other,
      doc: %{
        doc_id: "p1",
        title: "Remote Title",
        status: "draft",
        content: %{},
        updated_at: nil
      }
    }
  end

  describe "doc_updated concurrent-edit guard (#1)" do
    test "with unsaved local edits: does NOT overwrite the buffer, flags a conflict" do
      {:noreply, socket} = Lifecycle.doc_updated(remote_msg(), editor_socket(true))

      # The local buffer survives — no silent clobber.
      assert socket.assigns.editor_form == %{"title" => "Local Title", "status" => "draft"}
      # …and the reload banner is raised instead.
      assert socket.assigns.doc_conflict == true
      assert socket.assigns.save_status == "Updated by another user"
    end

    test "with NO unsaved edits: auto-refreshes the form in place (unchanged behaviour)" do
      {:noreply, socket} = Lifecycle.doc_updated(remote_msg(), editor_socket(false))

      # The remote snapshot is applied to the form.
      assert socket.assigns.editor_form["title"] == "Remote Title"
      assert socket.assigns.doc_conflict == false
      assert socket.assigns.save_status == "Updated by another user"
    end

    test "own write (sender == self) is ignored" do
      msg = %{remote_msg() | sender: self()}
      {:noreply, socket} = Lifecycle.doc_updated(msg, editor_socket(true))

      assert socket.assigns.editor_form == %{"title" => "Local Title", "status" => "draft"}
      assert socket.assigns.doc_conflict == false
    end
  end

  describe "document_changed concurrent-edit guard (#1)" do
    test "with unsaved local edits on the open type: skips the buffer-clobbering rebuild" do
      socket =
        editor_socket(true)
        |> put_in([Access.key!(:assigns), :editor_type], "post")
        |> put_in([Access.key!(:assigns), :nav_path], ["post", "p1"])

      {:noreply, out} = Lifecycle.document_changed(%{type: "post"}, socket)

      # No rebuild ran, so the buffer is intact (rebuild would reload from DB).
      assert out.assigns.editor_form == %{"title" => "Local Title", "status" => "draft"}
    end
  end

  describe "new_document id collision-resistance (#2)" do
    setup do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "icon" => "file-text",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )

      :ok
    end

    defp new_doc_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          dataset: @dataset,
          nav_path: ["post"],
          scope_prefix: ""
        }
      }
    end

    test "minted ids are <type>-<64-bit-hex>, never the old rand shape, and distinct" do
      for _ <- 1..40 do
        {:noreply, _socket} = Fields.new_document(%{"type" => "post"}, new_doc_socket())
      end

      # Read the created rows back (drafts) and normalize to published ids.
      ids =
        Content.list_documents("post", @dataset, perspective: :raw, limit: 1000)
        |> Enum.map(&Content.published_id(&1.doc_id))

      # 40 creates on the same dataset → all distinct (the rand bug collided
      # in a 1M-value space and silently overwrote colliding rows).
      assert length(ids) == 40
      assert length(Enum.uniq(ids)) == 40

      # Shape: `post-<16 lowercase hex>` — NOT the old `post-<1..6 digits>`.
      for id <- ids do
        assert id =~ ~r/^post-[0-9a-f]{16}$/
        refute id =~ ~r/^post-\d{1,6}$/
      end
    end
  end
end
