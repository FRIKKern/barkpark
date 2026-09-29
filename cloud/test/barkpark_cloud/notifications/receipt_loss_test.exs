defmodule BarkparkCloud.Notifications.ReceiptLossTest do
  @moduledoc """
  cch-w32-bl — the two receipt-loss branches, DRIVEN, not read.

  The whole defect this covers is a line that is PRESENT and never FIRES, so
  every arm here reaches the failure through a public caller (or through
  `rescue_receipt/3` at its own grain, the `Withhold.insert_suppressed/1`
  precedent) and observes a durable ROW, a telemetry event, or a captured log —
  never the source.

  THE DRIVER for the wired arm is a real production shape: an invite whose team
  is gone by the time the receipt is written. `Delivery.changeset/2` declares
  `assoc_constraint(:team)`, so the insert answers `{:error, changeset}` — the
  exact arm the fix replaced — while the email itself has already been accepted
  by the transport.

  `async: false` because the telemetry handlers are process-global.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, ReceiptLoss}
  alias BarkparkCloud.Repo

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp deliveries, do: Repo.all(Delivery)

  # Forward every receipt-loss event to this process. Returns nothing; the
  # assertions read the mailbox.
  defp listen! do
    ref = "receipt-loss-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      ref,
      ReceiptLoss.telemetry_event(),
      fn event, measurements, metadata, _ ->
        send(test, {:receipt_loss, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  describe "the record_delivery branch, driven for real" do
    test "an invite whose team is gone still lands a reduced receipt" do
      listen!()
      absent_team = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Notifications.deliver_invite(%{
                     to: "invitee@example.com",
                     url: "https://barkpark.cloud/invite/abc",
                     team_name: "Gone",
                     team_id: absent_team
                   })
        end)

      # THE TRACE, on the surface a person reads. Before the fix this list was
      # EMPTY and the only residue was a log line.
      assert [%Delivery{} = d] = deliveries()
      assert d.event == "invite"
      assert d.kind == "transactional"
      assert d.recipient == "invitee@example.com"
      # The transport verdict is preserved verbatim — the send DID happen.
      assert d.status == "sent"
      # The reference that was refused is what the reduction dropped.
      assert is_nil(d.team_id)

      assert_received {:receipt_loss, _event, %{count: 1},
                       %{site: :record_delivery, outcome: :reduced, stage: :identifying_only}}

      assert log =~ "could not record a delivery receipt"
      assert log =~ "REDUCED receipt"
    end

    test "CONTROL: a receipt that writes normally emits nothing and keeps its team" do
      listen!()
      team = team_fixture()

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Notifications.deliver_invite(%{
                     to: "invitee@example.com",
                     url: "https://barkpark.cloud/invite/abc",
                     team_name: team.name,
                     team_id: team.id
                   })
        end)

      assert [%Delivery{} = d] = deliveries()
      assert d.team_id == team.id
      assert d.status == "sent"

      # The success path must not start speaking the failure vocabulary.
      refute_received {:receipt_loss, _event, _measurements, _metadata}
      refute log =~ "could not record a delivery receipt"
      refute log =~ "REDUCED receipt"
    end
  end

  describe "the ladder, at its own grain" do
    test "a refused content column is dropped and the rest of the receipt survives" do
      listen!()
      team = team_fixture()

      # Over the retention ceiling: `validate_length(:content_subject)` refuses
      # it, and nothing else on the row is in question.
      attrs = %{
        team_id: team.id,
        recipient: "person@example.com",
        event: "fleet_digest",
        kind: "alert",
        status: "sent",
        attempts: 1,
        carrier: "platform",
        content_subject: String.duplicate("x", Delivery.subject_retention_limit() + 1)
      }

      refused = Delivery.changeset(%Delivery{}, attrs)
      refute refused.valid?

      assert {:reduced, %Delivery{} = d} =
               ReceiptLoss.rescue_receipt(:record_delivery, attrs, refused)

      # The FIRST rung: only the rendered material came off.
      assert d.team_id == team.id
      assert d.carrier == "platform"
      assert is_nil(d.content_subject)

      assert_received {:receipt_loss, _event, %{count: 1},
                       %{site: :record_delivery, outcome: :reduced, stage: :without_content}}
    end

    test "a receipt with no true row left is a NAMED residue, not a silence" do
      listen!()

      # No recipient: `validate_required([:recipient, :event])` refuses every
      # rung, and charter D362 forbids inventing an address to carry a row.
      attrs = %{
        team_id: nil,
        recipient: nil,
        event: "invite",
        kind: "transactional",
        status: "sent"
      }

      refused = Delivery.changeset(%Delivery{}, attrs)

      log =
        capture_log(fn ->
          assert :lost = ReceiptLoss.rescue_receipt(:record_delivery, attrs, refused)
        end)

      assert deliveries() == []
      assert log =~ "has NO receipt for a send that happened"

      assert_received {:receipt_loss, _event, %{count: 1},
                       %{site: :record_delivery, outcome: :lost}}
    end

    test "a rescue can never take the send down with it" do
      listen!()
      refused = Delivery.changeset(%Delivery{}, %{})

      log =
        capture_log(fn ->
          # `attempts` is an integer column; a struct there raises inside the
          # cast rather than answering an error changeset.
          assert :lost =
                   ReceiptLoss.rescue_receipt(
                     :record_delivery,
                     %{recipient: "p@example.com", event: "invite", attempts: self()},
                     refused
                   )
        end)

      assert log =~ "Notifications: record_delivery"
    end
  end

  describe "the adjudication register" do
    test "both receipt branches are adjudicated, and every entry states its verdict" do
      sites = ReceiptLoss.sites()

      for name <- [:record_delivery, :log_chat_delivery] do
        entry = ReceiptLoss.adjudication(name)
        assert entry, "#{name} has no adjudication"
        assert entry.adjudication == :traced
      end

      for entry <- sites do
        assert entry.adjudication in [:traced, :consented]
        assert is_binary(entry.why) and byte_size(entry.why) > 40
      end
    end
  end
end
