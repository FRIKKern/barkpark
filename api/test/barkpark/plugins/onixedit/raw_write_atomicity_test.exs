defmodule Barkpark.Plugins.OnixEdit.RawWriteAtomicityTest do
  @moduledoc """
  task-ff162c914cd0653c: OnixEdit's two state-preserving raw writers —
  `Bokbasen.Status.write/2` and the staleness console's acknowledge — must land
  the document update and its `mutation_events` row TOGETHER, under the
  write-admission door, with the fan-out after commit.

  Before, each ran a bare `Repo.update` (auto-commit, outside `Door.admit`) and
  only then `save_event` + broadcast. A fault on the event insert left the book
  changed with no event: no SSE frame, no webhook, no cache revalidation.

  The fault is the `RETURN NULL` trigger from
  `Barkpark.Content.PublishEventAtomicityTest` (see its moduledoc for why not a
  `RAISE`): `save_event`'s `Repo.insert!` raises `Ecto.StaleEntryError` with the
  Postgres transaction still healthy. Under the sandbox, "unchanged" means the
  update was fenced inside the same transaction as the event and rolled back.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `mutation_events`, on every mutation's write path.
  """
  # sync: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on `mutation_events`, on every mutation's write path
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status
  alias Barkpark.Repo

  @admin_token "onixedit-atomicity-admin-test-token"
  @url "/admin/onixedit/staleness"

  defp seed_book(content) do
    doc_id = "atomic-book-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Book " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  defp break_mutation_events! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_swallow_mutation_event() RETURNS trigger AS $fn$
    BEGIN
      RETURN NULL;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_swallow_mutation_event_trg
    BEFORE INSERT ON mutation_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_swallow_mutation_event()
    """)

    :ok
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  defp event_count(%Document{doc_id: doc_id}) do
    Repo.aggregate(from(e in MutationEvent, where: e.doc_id == ^doc_id), :count)
  end

  defp stale_content do
    %{
      "notificationType" => %{
        "codelistId" => "onixedit:notification_type",
        "issue_version" => "73"
      }
    }
  end

  describe "Bokbasen.Status.write/2" do
    test "a save_event fault leaves the book's status unchanged" do
      doc = seed_book(%{"bp_export_status" => %{"state" => "draft"}})
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn -> Status.write(doc, %{state: "polling"}) end

      assert Status.read(reload(doc)) == %{"state" => "draft"},
             "the status write survived a failed mutation_event insert — in production " <>
               "it is committed and no SSE/webhook consumer ever learns of it"
    end

    test "CONTROL: without the fault the write lands, with its event, and fans out" do
      doc = seed_book(%{"bp_export_status" => %{"state" => "draft"}})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:production")

      Status.write(doc, %{state: "polling"})

      assert Status.read(reload(doc))["state"] == "polling"
      assert event_count(doc) == 1
      doc_id = doc.doc_id
      assert_receive {:document_changed, %{doc_id: ^doc_id}}, 1_000
    end
  end

  describe "staleness acknowledge" do
    setup %{conn: conn} do
      {:ok, _} =
        Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    defp click_acknowledge(view, doc_id) do
      view
      |> element(~s|tr[data-test-doc-id="#{doc_id}"] button[data-test-action="acknowledge"]|)
      |> render_click()
    end

    # The LiveView dies on the raise; its crash report is expected noise.
    @tag :capture_log
    test "a save_event fault leaves the book unacknowledged", %{conn: conn} do
      doc = seed_book(stale_content())
      {:ok, view, _html} = live(conn, @url)
      break_mutation_events!()

      Process.flag(:trap_exit, true)
      catch_exit(click_acknowledge(view, doc.doc_id))

      refute reload(doc).content["staleness_acknowledged"],
             "the acknowledge survived a failed mutation_event insert"
    end

    test "CONTROL: without the fault the acknowledge lands with its event", %{conn: conn} do
      doc = seed_book(stale_content())
      {:ok, view, _html} = live(conn, @url)

      click_acknowledge(view, doc.doc_id)

      assert reload(doc).content["staleness_acknowledged"] == true
      assert event_count(doc) == 1
    end
  end
end
