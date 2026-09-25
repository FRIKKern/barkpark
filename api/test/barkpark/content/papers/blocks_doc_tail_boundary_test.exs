defmodule Barkpark.Content.Papers.BlocksDocTailBoundaryTest do
  @moduledoc """
  task-c352740ae6b0f72a — `persist_blocks_doc_tail/7` must run with NO
  transaction open.

  ## The mechanism

  `upsert_blocks_doc/3`'s slug-keyed clause opens a BARE `Repo.transaction` to
  take `pg_advisory_xact_lock`. Inside it, `Broadcast.write_atomically/1` NESTS
  (it runs its function as is whenever `Repo.in_transaction?/0` is true) and
  returns with the OUTER transaction still open, so the tail ran PRE-COMMIT:
  `broadcast_paper_update/1` is a raw `Phoenix.PubSub.broadcast` a subscriber
  can act on before the row is durable, and `enqueue_edge_projection/1`'s
  `Oban.insert/1` rides a transaction that can still roll back. The tail's own
  header comment asserts the opposite, which is what made the drift silent.

  ## The instrument

  `[:barkpark, :content, :blocks_doc, :tail]`, emitted as the FIRST statement of
  `persist_blocks_doc_tail/7` carrying the answer `Repo.in_transaction?/0` gives
  at that exact point. It fires on every reached tail, so a missing event is
  "the tail never ran", never "nobody was listening" — and the paper arm below
  is the control that proves the event fires at all.

  ## What the filing got wrong, pinned here as tests

  The row asserts `upsert_paper/2` routes through the locked clause. It does
  not: `upsert_blocks_doc(@paper_type, …)` is an EARLIER clause with no lock at
  all, so the paper arm was already correct and is kept here as a control. The
  live defect is the slug-keyed clause every OTHER blocks type takes.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Plugins.Bulldocs.Event
  alias Barkpark.Repo

  @dataset "production"
  @tail [:barkpark, :content, :blocks_doc, :tail]

  setup do
    for schema_def <- Barkpark.Plugins.Bulldocs.register_schemas([]),
        schema_def.name == "session" do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, [])
    end

    handler = "blocks-doc-tail-#{System.unique_integer([:positive])}"
    test = self()

    # `:telemetry.attach/4` is GLOBAL: the handler runs in whichever process
    # emits the event. This module is async, so without the guard every
    # concurrent test that writes a paper (paper_upsert_revision_trail_test's
    # `rev-trail-*` slugs, for one) delivered its {:tail, _} here, red-ing the
    # refused-write CONTROL and the session test's slug assertion by race.
    # Forward only events emitted by this test's process or a process it
    # spawned; the tail is emitted synchronously in the caller, so every event
    # this test causes still arrives.
    :telemetry.attach(
      handler,
      @tail,
      fn _event, _measurements, metadata, _ ->
        if self() == test or test in Process.get(:"$callers", []),
          do: send(test, {:tail, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp fresh_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp session_attrs(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "title" => "Tail boundary session", "status" => "open"}, extra)
  end

  defp paper_attrs(slug) do
    Barkpark.LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "title" => "Tail boundary paper",
      "blocks" => [
        %{
          "id" => "tpl-title",
          "type" => "heading",
          "level" => 1,
          "role" => "title",
          "locked" => true,
          "text" => "Tail boundary paper"
        },
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "A real body, not a hollow stub."}]
        }
      ]
    })
  end

  describe "criterion 0 — the tail runs outside every transaction" do
    test "a slug-carrying session upsert runs its tail with no transaction open" do
      slug = fresh_slug("tail-session")

      assert {:ok, _doc} = Content.upsert_blocks_doc("session", session_attrs(slug))

      assert_received {:tail, meta}
      assert meta.slug == slug
      assert meta.type == "session"

      assert meta.in_transaction == false,
             "persist_blocks_doc_tail/7 ran INSIDE the slug-keyed advisory lock's " <>
               "transaction — its pre-commit broadcast and Oban insert are the hazards " <>
               "the tail's own header comment claims are avoided"
    end

    test "CONTROL — the paper clause, which takes no lock, already ran its tail outside" do
      slug = fresh_slug("tail-paper")

      assert {:ok, _doc} = Content.upsert_paper(paper_attrs(slug))

      assert_received {:tail, meta}
      assert meta.type == "paper"
      assert meta.in_transaction == false
    end

    test "CONTROL — an UPDATE through the locked clause defers its tail too" do
      slug = fresh_slug("tail-session-update")

      assert {:ok, _} = Content.upsert_blocks_doc("session", session_attrs(slug))
      assert_received {:tail, _create}

      assert {:ok, _} =
               Content.upsert_blocks_doc("session", session_attrs(slug, %{"title" => "Second"}))

      assert_received {:tail, meta}
      assert meta.in_transaction == false
    end

    test "CONTROL — a refused write runs no tail at all" do
      # A hollow paper is refused by the quality gate before any row is written,
      # so no tail is queued and none is drained.
      slug = fresh_slug("tail-refused")

      assert {:error, {:halted, _}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "title" => "Hollow",
                   "blocks" => []
                 })
               )

      refute_received {:tail, _}
    end
  end

  describe "criterion 1 — a subscriber sees the tail's effects after commit, not during" do
    test "the {:paper_updated, …} frame is emitted with no transaction open, and the paper event row lands" do
      slug = fresh_slug("tail-subscriber")
      topic = Broadcast.paper_topic(slug, nil, @dataset)
      Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

      assert {:ok, doc} =
               Content.upsert_blocks_doc(
                 "session",
                 session_attrs(slug, %{
                   "event_type" => "tail-boundary-probe",
                   "payload_html" => "<p>probe</p>"
                 })
               )

      # The subscriber DOES get the frame today — the defect is WHEN. The tail
      # telemetry is what dates it: emitted from the same synchronous call, it
      # says whether the lock's transaction was still open when the raw
      # `Phoenix.PubSub.broadcast` and the `paper_events` insert went out.
      assert_received {:paper_updated, %{slug: ^slug}}
      assert_received {:tail, meta}

      assert meta.in_transaction == false,
             "the {:paper_updated, …} frame and the Bulldocs paper_events insert " <>
               "fired while the slug lock's transaction was still open — a subscriber " <>
               "that refetches on the frame reads state that is not durable yet"

      assert [event] =
               Repo.all(
                 from(e in Event,
                   where: e.paper_slug == ^slug and e.event_type == "tail-boundary-probe"
                 )
               )

      assert event.paper_slug == doc.doc_id
    end
  end
end
