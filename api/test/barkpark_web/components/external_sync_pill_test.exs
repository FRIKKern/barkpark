defmodule BarkparkWeb.Components.ExternalSyncPillTest do
  @moduledoc """
  Smoke coverage for `BarkparkWeb.Components.ExternalSyncPill`. The
  component is a thin renderer over `Barkpark.ExternalSync.state_meta/2`
  and `system_label/1` — these tests pin the visual contract (CSS class,
  data attributes, label prefix) so future registry edits don't silently
  break the badge.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.ExternalSyncPill

  describe "external_sync_pill/1 — Bokbasen states" do
    test "renders gray pill for nil state with 'Not synced' label" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: nil
        })

      assert html =~ ~s(bp-pill-gray)
      assert html =~ ~s(data-test-id="external-sync-pill-bokbasen")
      assert html =~ ~s(data-bp-system="bokbasen")
      assert html =~ "Bokbasen"
      assert html =~ "Not synced"
    end

    test "renders blue pill for 'staged'" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "staged"
        })

      assert html =~ ~s(bp-pill-blue)
      assert html =~ ~s(data-bp-state="staged")
      assert html =~ "Staged"
    end

    test "renders blue pill for 'polling'" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "polling"
        })

      assert html =~ ~s(bp-pill-blue)
      assert html =~ "Polling"
    end

    test "renders green pill for 'accepted'" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "accepted"
        })

      assert html =~ ~s(bp-pill-green)
      assert html =~ "Accepted"
    end

    test "renders red pill for 'rejected'" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "rejected"
        })

      assert html =~ ~s(bp-pill-red)
      assert html =~ "Rejected"
    end

    test "renders orange pill for terminal-error trio (failed, cancelled, cannot_cancel)" do
      for {state, label} <- [
            {"failed", "Failed"},
            {"cancelled", "Cancelled"},
            {"cannot_cancel", "Cannot cancel"}
          ] do
        html =
          render_component(&ExternalSyncPill.external_sync_pill/1, %{
            system: "bokbasen",
            state: state
          })

        assert html =~ ~s(bp-pill-orange), "expected orange for #{state}"
        assert html =~ label, "expected label #{inspect(label)} for #{state}"
      end
    end

    test "accepts atom states (atom → string normalisation)" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: :accepted
        })

      assert html =~ ~s(bp-pill-green)
      assert html =~ "Accepted"
    end

    test "unknown state falls back to the nil row of the system table" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "totally-made-up"
        })

      # Falls back to bokbasen's nil row → gray / "Not synced".
      assert html =~ ~s(bp-pill-gray)
      assert html =~ "Not synced"
    end
  end

  describe "external_sync_pill/1 — unknown system" do
    test "renders gray fallback pill instead of crashing" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "stripe",
          state: "ok"
        })

      assert html =~ ~s(bp-pill-gray)
      assert html =~ ~s(data-test-id="external-sync-pill-stripe")
      # System label falls back to the raw key when not registered.
      assert html =~ "stripe"
    end
  end

  describe "external_sync_pill/1 — hide_when_unsynced" do
    test "renders nothing when state is nil and hide_when_unsynced is true" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: nil,
          hide_when_unsynced: true
        })

      refute html =~ ~s(external-sync-pill-bokbasen)
    end

    test "still renders when state is non-nil and hide_when_unsynced is true" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "polling",
          hide_when_unsynced: true
        })

      assert html =~ ~s(external-sync-pill-bokbasen)
      assert html =~ "Polling"
    end
  end

  describe "external_sync_pill/1 — tooltip" do
    test "passes tooltip into the title attribute" do
      html =
        render_component(&ExternalSyncPill.external_sync_pill/1, %{
          system: "bokbasen",
          state: "rejected",
          tooltip: "ISBN 978-… rejected by Bokbasen: missing contributor"
        })

      assert html =~
               ~s(title="ISBN 978-… rejected by Bokbasen: missing contributor")
    end
  end

  describe "Barkpark.ExternalSync — registry contract (sibling sanity check)" do
    test "topic/2 follows external_sync:<system>:<doc_id> convention" do
      assert Barkpark.ExternalSync.topic("bokbasen", "drafts.book-1") ==
               "external_sync:bokbasen:drafts.book-1"
    end

    test "broadcast/4 delivers the {:external_sync_status, …} message to a subscriber" do
      doc_id = "test-doc-#{System.unique_integer([:positive])}"
      :ok = Barkpark.ExternalSync.subscribe("bokbasen", doc_id)

      :ok =
        Barkpark.ExternalSync.broadcast("bokbasen", doc_id, "accepted", %{"state" => "accepted"})

      assert_receive {:external_sync_status,
                      %{
                        system: "bokbasen",
                        doc_id: ^doc_id,
                        state: "accepted",
                        payload: %{"state" => "accepted"}
                      }},
                     1_000
    end
  end
end
