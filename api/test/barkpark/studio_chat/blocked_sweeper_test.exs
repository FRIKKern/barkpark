defmodule Barkpark.StudioChat.BlockedSweeperTest do
  @moduledoc """
  The walk-away-safety sweep (herd layer, charter D57h–D59h): a session blocked
  past its workspace threshold fires EXACTLY ONE debounced webhook; answering
  fires nothing; a NULL-owner session never fires (fail-closed, D43h).

  Driven through the PURE `sweep(now)` with an injected clock — the boot/60s
  GenServer wiring is the AgentStateSweeper twin and is not re-tested here.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.StudioChat.{BlockedSweeper, Message, Session}
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Delivery

  @threshold_s 300

  # An adapter whose post/3 echoes to a pid so a delivery is observable.
  defmodule PidEcho do
    def post(url, body, _headers) do
      case Application.get_env(:barkpark, :blocked_sweeper_test_pid) do
        pid when is_pid(pid) -> send(pid, {:delivered, url, body})
        _ -> :ok
      end

      {:ok, 200}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, PidEcho)
    Application.put_env(:barkpark, :blocked_sweeper_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      Application.delete_env(:barkpark, :blocked_sweeper_test_pid)
    end)

    :ok
  end

  defp chat_blocked_hook(ws, threshold \\ @threshold_s) do
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

  defp session!(owner_workspace_id, title \\ "Deploy the thing") do
    id = Ecto.UUID.generate()

    {:ok, s} =
      %Session{}
      |> Session.create_changeset(%{
        id: id,
        owner_workspace_id: owner_workspace_id,
        title: title
      })
      |> Repo.insert()

    s
  end

  defp ask!(session, role \\ "approval", status \\ "pending") do
    {:ok, m} =
      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        seq: System.unique_integer([:positive]),
        role: role,
        metadata: %{"approval_status" => status}
      })
      |> Repo.insert()

    m
  end

  # A clock far enough past the ask's inserted_at that the threshold is exceeded.
  defp past_threshold, do: DateTime.add(DateTime.utc_now(), @threshold_s + 60, :second)

  defp delivery_count do
    Delivery |> where([d], d.source_kind == "chat_blocked") |> Repo.aggregate(:count)
  end

  test "blocked past threshold fires EXACTLY ONE delivery; a second sweep no-ops" do
    ws = create_workspace!()
    _wh = chat_blocked_hook(ws)
    session = session!(ws.id)
    ask = ask!(session)

    assert BlockedSweeper.sweep(past_threshold()) == 1
    assert_received {:delivered, "https://sink.example/blocked", body}

    # Payload carries exactly the herd fields, never message content.
    payload = Jason.decode!(body)
    assert payload["session_id"] == session.id
    assert payload["title"] == "Deploy the thing"
    assert payload["workspace_id"] == ws.id
    assert payload["ask_role"] == "approval"
    assert is_binary(payload["blocked_since"])
    refute Map.has_key?(payload, "content")
    refute Map.has_key?(payload, "input")
    refute Map.has_key?(payload, "source_markdown")

    # blocked_since is the ASK row's inserted_at.
    assert payload["blocked_since"] == DateTime.to_iso8601(ask.inserted_at)

    # Second pass: the dedupe row makes it a no-op (no new delivery, no new echo).
    assert BlockedSweeper.sweep(past_threshold()) == 0
    refute_received {:delivered, _, _}
    assert delivery_count() == 1
  end

  test "an ask answered within the threshold fires nothing" do
    ws = create_workspace!()
    _wh = chat_blocked_hook(ws)
    session = session!(ws.id)
    ask = ask!(session)

    # Answered before the threshold elapses → leaves the pending scan.
    {:ok, _} =
      ask
      |> Ecto.Changeset.change(metadata: %{"approval_status" => "approved"})
      |> Repo.update()

    assert BlockedSweeper.sweep(past_threshold()) == 0
    refute_received {:delivered, _, _}
    assert delivery_count() == 0
  end

  test "a still-pending ask WITHIN the threshold fires nothing (not yet owed)" do
    ws = create_workspace!()
    _wh = chat_blocked_hook(ws)
    session = session!(ws.id)
    _ask = ask!(session)

    # now = wall clock: the ask is fresh, cutoff is in the past → not yet due.
    assert BlockedSweeper.sweep(DateTime.utc_now()) == 0
    refute_received {:delivered, _, _}
  end

  test "a session with a NULL owner_workspace_id never fires (fail-closed, D43h)" do
    ws = create_workspace!()
    # A chat_blocked hook exists in a real workspace, but the blocked session is
    # owner-less (admin :global / pre-migration) — a NULL never matches the ws.
    _wh = chat_blocked_hook(ws)
    session = session!(nil)
    _ask = ask!(session)

    assert BlockedSweeper.sweep(past_threshold()) == 0
    refute_received {:delivered, _, _}
    assert delivery_count() == 0
  end

  test "a workspace with no chat_blocked webhook fires nothing" do
    ws = create_workspace!()
    session = session!(ws.id)
    _ask = ask!(session)

    assert BlockedSweeper.sweep(past_threshold()) == 0
    refute_received {:delivered, _, _}
  end

  test "a NEW ask after answering the first is a legitimate fresh fire" do
    ws = create_workspace!()
    _wh = chat_blocked_hook(ws)
    session = session!(ws.id)
    ask1 = ask!(session)

    assert BlockedSweeper.sweep(past_threshold()) == 1
    assert_received {:delivered, _, _}

    # Answer the first ask, then a brand-new ask (fresh row/id) appears.
    {:ok, _} =
      ask1
      |> Ecto.Changeset.change(metadata: %{"approval_status" => "approved"})
      |> Repo.update()

    _ask2 = ask!(session, "question")

    assert BlockedSweeper.sweep(past_threshold()) == 1
    assert_received {:delivered, _, body}
    assert Jason.decode!(body)["ask_role"] == "question"
    assert delivery_count() == 2
  end

  test "each ask past threshold in the same workspace fires its own notification" do
    ws = create_workspace!()
    _wh = chat_blocked_hook(ws)
    s1 = session!(ws.id, "one")
    s2 = session!(ws.id, "two")
    _a1 = ask!(s1)
    _a2 = ask!(s2, "plan")

    assert BlockedSweeper.sweep(past_threshold()) == 2
    assert delivery_count() == 2
  end
end
