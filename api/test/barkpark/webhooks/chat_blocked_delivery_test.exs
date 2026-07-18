defmodule Barkpark.Webhooks.ChatBlockedDeliveryTest do
  @moduledoc """
  The chat_blocked webhook seam (herd layer, charter D57h–D59h): the
  exactly-once claim, the workspace-scoped subscription selector, the
  channel-separation guards, and the crash-recovery rebuild.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Delivery, PayloadRebuild}

  defp chat_blocked_hook(ws, threshold \\ 300) do
    {:ok, wh} =
      Webhooks.create_webhook(
        %{
          "name" => "cb-#{System.unique_integer([:positive])}",
          "url" => "https://sink.example/blocked",
          "secret" => "sek",
          "blocked_threshold_s" => threshold
        },
        workspace_id: ws.id
      )

    wh
  end

  describe "Delivery.changeset/2 — chat_blocked required fields" do
    test "requires endpoint_id, payload_snapshot AND dedupe_key; event_id stays NULL" do
      cs =
        Delivery.changeset(%Delivery{}, %{
          source_kind: "chat_blocked",
          endpoint_id: "11111111-1111-1111-1111-111111111111",
          dedupe_key: "42",
          payload_snapshot: %{"body" => "{}"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :event_id) == nil
    end

    test "is invalid when dedupe_key is missing" do
      cs =
        Delivery.changeset(%Delivery{}, %{
          source_kind: "chat_blocked",
          endpoint_id: "11111111-1111-1111-1111-111111111111",
          payload_snapshot: %{"body" => "{}"}
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :dedupe_key)
    end

    test "is invalid when payload_snapshot is missing" do
      cs =
        Delivery.changeset(%Delivery{}, %{
          source_kind: "chat_blocked",
          endpoint_id: "11111111-1111-1111-1111-111111111111",
          dedupe_key: "42"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :payload_snapshot)
    end
  end

  describe "claim_chat_blocked_delivery/3 — exactly-once" do
    test "first claim inserts; the SECOND claim for the same (endpoint, dedupe_key) is rejected" do
      ws = create_workspace!()
      wh = chat_blocked_hook(ws)

      assert {:ok, %Delivery{} = d} =
               Webhooks.claim_chat_blocked_delivery(wh.id, "777", %{"body" => "{}"})

      assert d.source_kind == "chat_blocked"
      assert d.dedupe_key == "777"
      assert d.event_id == nil

      # Same ask id again → already delivered (the debounce that makes a re-sweep
      # of a still-blocked session a no-op).
      assert {:error, :already_delivered} =
               Webhooks.claim_chat_blocked_delivery(wh.id, "777", %{"body" => "{}"})

      # Exactly one row for the pair.
      count =
        Delivery
        |> where([x], x.endpoint_id == ^wh.id and x.dedupe_key == "777")
        |> Repo.aggregate(:count)

      assert count == 1
    end

    test "a DIFFERENT dedupe_key (a new ask) is a fresh claim" do
      ws = create_workspace!()
      wh = chat_blocked_hook(ws)

      assert {:ok, _} = Webhooks.claim_chat_blocked_delivery(wh.id, "1", %{"body" => "{}"})
      assert {:ok, _} = Webhooks.claim_chat_blocked_delivery(wh.id, "2", %{"body" => "{}"})
    end
  end

  describe "chat_blocked_webhooks_for/1 — workspace-scoped subscription selector" do
    test "returns only active, thresholded webhooks for THAT workspace" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      wh_a = chat_blocked_hook(ws_a)
      _wh_b = chat_blocked_hook(ws_b)

      ids = ws_a.id |> Webhooks.chat_blocked_webhooks_for() |> Enum.map(& &1.id)
      assert ids == [wh_a.id]
    end

    test "a workspace webhook WITHOUT a threshold (off) is not selected" do
      ws = create_workspace!()

      {:ok, _plain} =
        Webhooks.create_webhook(
          %{"name" => "plain", "url" => "https://sink.example/c", "secret" => "s"},
          workspace_id: ws.id
        )

      assert Webhooks.chat_blocked_webhooks_for(ws.id) == []
    end

    test "audit_webhooks_for's semantics are untouched — a chat_blocked hook is not an audit subscriber" do
      ws = create_workspace!()
      _wh = chat_blocked_hook(ws)

      # A chat_blocked hook has empty audit_categories, so it never appears in the
      # audit fan-out selection (its org-only semantics stand).
      assert Webhooks.audit_webhooks_for("auth", "sso_login", nil) == []
    end

    test "a chat_blocked hook is excluded from CONTENT fan-out (channels never cross)" do
      ws = create_workspace!()
      _wh = chat_blocked_hook(ws)

      # Its default empty events/types would otherwise match every content event;
      # active_webhooks_for/4 must exclude thresholded rows.
      assert Webhooks.active_webhooks_for("production", "create", "post", workspace_id: ws.id) ==
               []
    end
  end

  describe "PayloadRebuild.rebuild/1 — chat_blocked resumes from snapshot, never Repo.get(nil)" do
    test "a retried chat_blocked row rebuilds {webhook, body} from payload_snapshot" do
      ws = create_workspace!()
      wh = chat_blocked_hook(ws)
      body = Jason.encode!(%{"session_id" => "s1", "ask_role" => "approval"})

      {:ok, delivery} = Webhooks.claim_chat_blocked_delivery(wh.id, "99", %{"body" => body})

      # The catch-all clause would call Repo.get(MutationEvent, nil) and RAISE on
      # the NULL event_id; our chat_blocked clause returns the live webhook + the
      # snapshotted body instead.
      assert {:ok, rebuilt_wh, ^body} = PayloadRebuild.rebuild(delivery)
      assert rebuilt_wh.id == wh.id
    end

    test ":gone when the target webhook was deleted" do
      ws = create_workspace!()
      wh = chat_blocked_hook(ws)
      {:ok, delivery} = Webhooks.claim_chat_blocked_delivery(wh.id, "100", %{"body" => "{}"})

      Repo.delete!(wh)

      assert PayloadRebuild.rebuild(delivery) == :gone
    end
  end
end
