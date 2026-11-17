defmodule Barkpark.ChatHosts.HandedOutStampTest do
  @moduledoc """
  A host poll stamps `handed_out_at` on every lease it hands out
  (task-b1e2f61ca03df99b), so a same-key resend never puts back on the queue a
  lease a host may have run. The stamp is one UPDATE per poll for the leases
  not stamped yet, and no write at all on a poll that hands out only stamped
  leases.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy

  test "a poll stamps every lease it hands out in one UPDATE; a later poll writes nothing" do
    %{host: host, session_id: session_id} = host_session()
    a = leased_turn(host, session_id, "a")
    b = leased_turn(host, session_id, "b")
    assert stamps([a, b]) == [nil, nil]

    {first, updates} = count_lease_updates(fn -> ChatHosts.next_commands(host) end)
    assert first |> Enum.map(& &1.lease_id) |> Enum.sort() == Enum.sort([a, b])
    assert updates == 1
    [stamp_a, stamp_b] = stamps([a, b])
    assert stamp_a != nil and stamp_b != nil

    {_again, updates} = count_lease_updates(fn -> ChatHosts.next_commands(host) end)
    assert updates == 0
    assert stamps([a, b]) == [stamp_a, stamp_b]
  end

  test "a poll that hands out nothing writes nothing" do
    %{host: host} = host_session()
    {[], updates} = count_lease_updates(fn -> ChatHosts.next_commands(host) end)
    assert updates == 0
  end

  defp stamps(ids) do
    rows =
      Repo.all(from(l in ExecutionLease, where: l.id in ^ids, select: {l.id, l.handed_out_at}))

    Enum.map(ids, &(rows |> Map.new() |> Map.fetch!(&1)))
  end

  # UPDATE statements on chat_execution_leases the calling process issues,
  # counted from Ecto's own telemetry.
  defp count_lease_updates(fun) do
    me = self()
    ref = make_ref()
    id = "handed-out-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ ->
        if self() == me and meta[:source] == "chat_execution_leases" and
             String.starts_with?(meta[:query] || "", "UPDATE"),
           do: send(me, {ref, :update})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain(ref, 0)}
  end

  defp drain(ref, n) do
    receive do
      {^ref, :update} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp leased_turn(host, session_id, tag) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: session_id,
      idempotency_key: "handed-#{tag}-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello"}
    }

    {:ok, %{lease_id: lease_id}} = ChatHosts.lease_and_enqueue(host, command, [])
    lease_id
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "chat-host-handed-#{suffix}", name: "W"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: "laptop", approved_roots: [System.tmp_dir!()]})

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token)
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    session_id = Ecto.UUID.generate()

    {:ok, _} =
      %Session{}
      |> Session.create_changeset(%{
        id: session_id,
        owner_workspace_id: ws.id,
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host.id
      })
      |> Repo.insert()

    %{host: host, session_id: session_id}
  end
end
