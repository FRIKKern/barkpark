defmodule Barkpark.AuditTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Audit
  alias Barkpark.Audit.{Chain, Event}
  alias Barkpark.Content

  @ws Ecto.UUID.generate()
  @ws_b Ecto.UUID.generate()

  defp emit!(attrs) do
    {:ok, ev} = Audit.emit(Map.merge(%{category: "auth", action: "login_succeeded"}, attrs))
    ev
  end

  describe "emit/1 — append + hash chain" do
    test "first row of a workspace chains off genesis; returns the event" do
      ev = emit!(%{workspace_id: @ws, actor_id: "u1"})

      assert ev.id
      assert ev.category == "auth"
      assert is_nil(ev.prev_hash)
      assert ev.hash == Chain.hash(chain_fields(ev), Chain.genesis())
    end

    test "second row chains off the first (prev_hash = first.hash)" do
      a = emit!(%{workspace_id: @ws, action: "login_succeeded", actor_id: "u1"})
      b = emit!(%{workspace_id: @ws, action: "session_revoked", actor_id: "u1"})

      assert b.prev_hash == a.hash
      assert :ok == Audit.verify_chain(@ws)
    end

    test "stamps occurred_at when absent" do
      ev = emit!(%{workspace_id: @ws})
      assert %DateTime{} = ev.occurred_at
    end

    test "rejects an unknown category" do
      assert {:error, %Ecto.Changeset{}} = Audit.emit(%{category: "bogus", action: "x"})
    end
  end

  describe "per-workspace isolation" do
    test "each workspace keeps an independent chain, both verifiable" do
      emit!(%{workspace_id: @ws, action: "login_succeeded", actor_id: "a"})
      emit!(%{workspace_id: @ws_b, action: "login_succeeded", actor_id: "b"})
      emit!(%{workspace_id: @ws, action: "session_revoked", actor_id: "a"})

      # ws_b's single row is genesis-rooted, independent of ws's two rows.
      [b_row] = Audit.list_for_workspace(@ws_b)
      assert is_nil(b_row.prev_hash)

      assert :ok == Audit.verify_chain(@ws)
      assert :ok == Audit.verify_chain(@ws_b)
    end
  end

  describe "append-only enforcement (DB trigger)" do
    test "UPDATE is rejected at the DB layer" do
      ev = emit!(%{workspace_id: @ws})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE audit_events SET action = 'tampered' WHERE id = $1", [ev.id])
      end
    end

    test "DELETE is rejected at the DB layer" do
      ev = emit!(%{workspace_id: @ws})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM audit_events WHERE id = $1", [ev.id])
      end
    end
  end

  describe "verify_chain — tamper detection (pure)" do
    test "Chain.verify flags a row whose hash was altered" do
      good = %{
        id: 1,
        category: "auth",
        action: "login_succeeded",
        subject: nil,
        actor_type: "user",
        actor_id: "u1",
        workspace_id: @ws,
        project_id: nil,
        metadata: %{},
        occurred_at: DateTime.utc_now(),
        prev_hash: nil,
        hash: nil
      }

      good = %{good | hash: Chain.hash(good, Chain.genesis())}
      assert :ok == Chain.verify([good])

      tampered = %{good | action: "session_revoked"}
      assert {:error, {:broken_at, 1}} = Chain.verify([tampered])
    end
  end

  describe "content mutation emits an audit event (integration)" do
    test "create_document writes a content_mutation row for the doc" do
      dataset = "test"

      {:ok, doc} =
        Content.create_document(
          "author",
          %{"_id" => "audit-author-1", "title" => "Audited"},
          dataset,
          user_id: "editor-42"
        )

      rows = Repo.all(from e in Event, where: e.category == "content_mutation")
      assert row = Enum.find(rows, &(&1.subject == doc.doc_id))
      assert row.action == "document.create"
      assert row.actor_type == "user"
      assert row.actor_id == "editor-42"
      assert row.metadata["type"] == "author"
      assert row.metadata["dataset"] == dataset
    end
  end

  defp chain_fields(ev) do
    %{
      category: ev.category,
      action: ev.action,
      subject: ev.subject,
      actor_type: ev.actor_type,
      actor_id: ev.actor_id,
      workspace_id: ev.workspace_id,
      project_id: ev.project_id,
      metadata: ev.metadata,
      occurred_at: ev.occurred_at
    }
  end
end
