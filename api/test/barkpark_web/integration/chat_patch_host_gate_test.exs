defmodule BarkparkWeb.Integration.ChatPatchHostGateTest do
  @moduledoc """
  task-14e61a60450c4678: `PATCH /v1/chat/sessions/:id` with a changed `mode`,
  `model_choice` or `effort_choice` steers a LIVE runtime (`apply_patch_op/2`
  → `Runtime.steer/3`), so it must pass the same
  `HostExecutionGate.authorize_turn/2` check `/messages` makes. Before the fix,
  a Default-bound chat token that is not on the armed operator allowlist got
  200 and the running host CLI switched to `acceptEdits`.

  The runtime is a claude session on the global `:self_hosted` profile whose
  stdin is `tee`d to a file. A refusal is proven by ORDERING: the operator's
  later steer goes through the same Session, so once it is on the wire the
  refused one never will be.

  The gate decides once, on the one row snapshot the request read: the two
  window tests inject a write (or a runtime coming up) between that decision
  and the apply, where a second read used to decide again.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  setup do
    {default_ws, _} = ensure_default_scope!()
    wire = Path.join(System.tmp_dir!(), "patch-gate-#{System.unique_integer([:positive])}")
    keys = [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]
    prev = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      execution_profile: :self_hosted,
      command: {"sh", ["-c", "tee '#{wire}' >/dev/null"]}
    )

    Application.put_env(:barkpark, :public_demo_studio, false)

    # The operator allowlist, armed: only `op` is an instance principal.
    op = "patchgate-op-#{System.unique_integer([:positive])}"
    {:ok, op_token} = Auth.create_token(op, "op", "production", ["read", "write", "admin"])
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [op_token.id])

    # A Default-bound chat token: sees Default-owned sessions, is not on the list.
    seat = "patchgate-seat-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(seat, "seat", "production", ["chat"], default_ws.id)

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end

      File.rm(wire)
    end)

    %{default_ws: default_ws, op: op, seat: seat, wire: wire}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp patch_session(raw, sid, body),
    do: as(raw) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(body))

  # A managed claude session owned by the Default workspace (a host turn under
  # :self_hosted); `live?` brings its runtime up.
  defp host_session!(ws, live?) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{id: sid, cwd: ClaudeChat.cwd(), mode: "plan", provider: "claude"},
        {:workspace, ws.id}
      )

    if live? do
      {:ok, recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
      assert {:ok, pid} = Recorder.session_pid(recorder)
      assert is_pid(pid), "the precondition: a live runtime"
    end

    sid
  end

  defp wire_text(wire), do: if(File.exists?(wire), do: File.read!(wire), else: "")

  defp steers(wire) do
    wire
    |> wire_text()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok,
         %{"type" => "control_request", "request" => %{"subtype" => "set_permission_mode"} = r}} ->
          [{:mode, r["mode"]}]

        {:ok, %{"type" => "control_request", "request" => %{"subtype" => "set_model"} = r}} ->
          [{:model, r["model"]}]

        _ ->
          []
      end
    end)
  end

  defp await_steer(wire, steer, tries \\ 200) do
    cond do
      steer in steers(wire) -> true
      tries <= 0 -> flunk("#{inspect(steer)} never reached the wire: #{inspect(steers(wire))}")
      true -> Process.sleep(20) && await_steer(wire, steer, tries - 1)
    end
  end

  defp refused?(resp),
    do:
      resp.status == 403 and
        json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"

  test "a non-instance principal's mode or model PATCH on a live host session is refused",
       %{default_ws: ws, op: op, seat: seat, wire: wire} do
    sid = host_session!(ws, true)

    mode = patch_session(seat, sid, %{mode: "acceptEdits"})
    assert refused?(mode), "mode PATCH answered #{mode.status}, the turn door is 403"

    model = patch_session(seat, sid, %{model_choice: "opus", draft: "kept out too"})
    assert refused?(model), "model PATCH answered #{model.status}, the turn door is 403"

    row = StudioChat.get_session(sid, :global)
    assert {row.mode, row.model_choice, row.draft} == {"plan", nil, nil}

    assert patch_session(op, sid, %{model_choice: "sonnet"}).status == 200
    assert await_steer(wire, {:model, "sonnet"})
    assert steers(wire) == [{:model, "sonnet"}]
  end

  test "CONTROL: the instance principal steers mode and model live (200)",
       %{default_ws: ws, op: op, wire: wire} do
    sid = host_session!(ws, true)

    assert patch_session(op, sid, %{mode: "acceptEdits", model_choice: "opus"}).status == 200
    assert await_steer(wire, {:mode, "acceptEdits"})
    assert await_steer(wire, {:model, "opus"})
    assert StudioChat.get_session(sid, :global).mode == "acceptEdits"
  end

  # task-242dea9cceb7dd7e: an offline mode/model change is refused too (the next
  # spawn reads it); chat_saved_mode_host_gate_test.exs pins that end to end.
  test "CONTROL: an echo, a draft and effort pass for the same principal",
       %{default_ws: ws, seat: seat, wire: wire} do
    live = host_session!(ws, true)
    assert patch_session(seat, live, %{mode: "plan", draft: "leave echo"}).status == 200
    assert StudioChat.get_session(live, :global).draft == "leave echo"

    # Effort never steers (no adapter applies it), so it is intent here as in
    # Studio's set-effort: a live session takes it from the same principal.
    assert patch_session(seat, live, %{effort_choice: "high"}).status == 200
    assert StudioChat.get_session(live, :global).effort_choice == "high"
    assert steers(wire) == []
  end

  # The window between the PATCH's gate and its apply, injected without a
  # sleep or a race: the request runs in this process, and its `draft` UPDATE
  # (the first op applied) fires Ecto's query telemetry here, so `fun` runs
  # exactly once, after the gate decided and before the mode op is applied.
  defp between_gate_and_apply(fun) do
    test_pid = self()
    handler = "patch-gate-window-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _ ->
        query = meta[:query] || ""

        if self() == test_pid and not Process.get(handler, false) and
             String.starts_with?(query, ~s(UPDATE "chat_sessions")) and
             String.contains?(query, ~s("draft")) do
          Process.put(handler, true)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  test "an echo that passed the gate never steers back a change that landed after it",
       %{default_ws: ws, op: op, seat: seat, wire: wire} do
    sid = host_session!(ws, true)
    # The operator's switch lands between the seat's gate and its apply.
    fired = between_gate_and_apply(fn -> StudioChat.set_mode(sid, "acceptEdits") end)

    assert patch_session(seat, sid, %{draft: "x", mode: "plan"}).status == 200
    assert Process.get(fired), "the precondition: the window was entered"

    assert patch_session(op, sid, %{model_choice: "sonnet"}).status == 200
    assert await_steer(wire, {:model, "sonnet"})
    refute {:mode, "plan"} in steers(wire), "the refused principal steered the live CLI"
    # ...and its stale echo did not overwrite the operator's persisted choice.
    assert StudioChat.get_session(sid, :global).mode == "acceptEdits"
  end

  # The operator passes the gate offline (a non-operator no longer does,
  # task-242dea9cceb7dd7e): its change is saved, but never steered into a
  # runtime the check did not see.
  test "a change the gate saw offline is never steered into a runtime that came up after it",
       %{default_ws: ws, op: op, wire: wire} do
    sid = host_session!(ws, false)

    fired =
      between_gate_and_apply(fn ->
        {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
      end)

    assert patch_session(op, sid, %{draft: "x", mode: "acceptEdits"}).status == 200
    assert Process.get(fired), "the precondition: the window was entered"

    assert patch_session(op, sid, %{model_choice: "sonnet"}).status == 200
    assert await_steer(wire, {:model, "sonnet"})
    refute {:mode, "acceptEdits"} in steers(wire), "a runtime the gate never saw was steered"
  end
end
