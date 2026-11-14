defmodule BarkparkWeb.Integration.ChatSavedModeHostGateTest do
  @moduledoc """
  task-242dea9cceb7dd7e: a saved permission mode or model is not inert. The
  next turn spawns from the row (`ensure_and_send/4` passes `mode:
  session.mode` and the model choice), so a principal who may not take a host
  turn on a session may not write its mode or model either, whether or not a
  runtime is up, through either door: `PATCH /v1/chat/sessions/:id` and the
  Studio tab.

  Before the fix, with the operator allowlist armed, a non-operator wrote
  `acceptEdits` to an offline host session's row (PATCH 200, or a Studio tab's
  set-mode), and the operator's next `POST /messages` spawned the host CLI with
  `--permission-mode acceptEdits`. A Studio tab that opened while the session
  was offline holds no pid, so it kept writing the row after the runtime came up
  elsewhere: the tab checked its own assigns, not the runtime.

  The host binary is a stub (the `:binary` override keeps `build_args/2`) that
  writes its argv, one flag per line, then drains stdin: the argv IS the spawn.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Barkpark.TenancyFixtures, only: [ensure_default_scope!: 0]
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.HostExecution
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ClaudeChat

  setup do
    {default_ws, _} = ensure_default_scope!()

    dir = Path.join(System.tmp_dir!(), "saved-mode-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    argv = Path.join(dir, "argv")
    stub = Path.join(dir, "fake-claude")
    # Write aside, then rename: a reader never sees half an argv.
    File.write!(
      stub,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{argv}.tmp' && mv '#{argv}.tmp' '#{argv}'\nexec cat >/dev/null\n"
    )

    File.chmod!(stub, 0o755)

    keys = [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]
    prev = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      binary: stub,
      execution_profile: :self_hosted
    )

    Application.put_env(:barkpark, :public_demo_studio, false)

    # The operator allowlist, armed: only `op` is an instance principal.
    op = "savedmode-op-#{System.unique_integer([:positive])}"
    {:ok, op_token} = Auth.create_token(op, "op", "production", ["read", "write", "admin"])
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [op_token.id])

    # A Default-bound chat token: sees Default-owned sessions, is not on the list.
    seat = "savedmode-seat-#{System.unique_integer([:positive])}"
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

      File.rm_rf(dir)
    end)

    %{default_ws: default_ws, op: op, seat: seat, argv: argv}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp patch_session(raw, sid, body),
    do: as(raw) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(body))

  # A managed claude session owned by the Default workspace (a host turn under
  # :self_hosted), in plan mode, runtime offline.
  defp host_session!(ws) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{id: sid, cwd: ClaudeChat.cwd(), mode: "plan", provider: "claude"},
        {:workspace, ws.id}
      )

    sid
  end

  # The operator's next turn over HTTP; returns the argv the host CLI spawned with.
  defp operator_turn_argv!(op, sid, argv) do
    resp =
      as(op)
      |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "operator turn"}))

    assert resp.status == 202, "operator turn: #{resp.status} #{resp.resp_body}"
    await_argv(argv)
  end

  # The argv the host CLI spawned with, once it has spawned.
  defp await_argv(argv) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      if File.exists?(argv) and File.read!(argv) =~ "--permission-mode",
        do: {:halt, File.read!(argv) |> String.split("\n", trim: true)},
        else: Process.sleep(20) && {:cont, nil}
    end) || flunk("the host binary never spawned")
  end

  defp flag(args, name) do
    case Enum.drop_while(args, &(&1 != name)) do
      [^name, value | _] -> value
      _ -> nil
    end
  end

  defp refused?(resp),
    do:
      resp.status == 403 and
        json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"

  defp default_admin_user!(ws) do
    user = register_user("savedmode-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")
    user
  end

  defp mount_user(conn, user, path) do
    {:ok, session} = Accounts.create_user_session_token(user)
    {:ok, view, _} = live(init_test_session(conn, %{"user_session" => session}), path)
    view
  end

  defp mount_token(conn, raw, path) do
    {:ok, view, _} = live(init_test_session(conn, %{"api_token" => raw}), path)
    view
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp refusal,
    do: HostExecution.message() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp row(sid), do: StudioChat.get_session(sid, :global)

  defp row_ids, do: Barkpark.Repo.all(from(s in StudioChat.Session, select: s.id))

  defp create_session(raw, body), do: as(raw) |> post("/v1/chat/sessions", Jason.encode!(body))

  defp send_from(tab, text) do
    render_submit(element(tab, "form[phx-submit=send]"), %{"message" => text})
    render(tab)
  end

  # What the operator's next turn on each row spawns with: {mode, model}.
  defp operator_spawns(op, sids, argv) do
    for sid <- sids do
      args = operator_turn_argv!(op, sid, argv)
      File.rm(argv)
      {flag(args, "--permission-mode"), flag(args, "--model")}
    end
  end

  describe "allowlist armed: a non-operator may not save a host session's mode or model" do
    test "PATCH on an offline session is refused, and the operator's next turn spawns in plan",
         %{default_ws: ws, op: op, seat: seat, argv: argv} do
      sid = host_session!(ws)

      mode = patch_session(seat, sid, %{mode: "acceptEdits"})
      model = patch_session(seat, sid, %{model_choice: "opus", draft: "kept out too"})

      args = operator_turn_argv!(op, sid, argv)
      assert {flag(args, "--permission-mode"), flag(args, "--model")} == {"plan", nil}

      assert refused?(mode), "mode PATCH answered #{mode.status}, the turn door is 403"
      assert refused?(model), "model PATCH answered #{model.status}, the turn door is 403"
      assert {row(sid).mode, row(sid).model_choice, row(sid).draft} == {"plan", nil, nil}
    end

    test "a Studio tab on an offline session saves nothing, and the operator's next turn spawns in plan",
         %{conn: conn, default_ws: ws, op: op, argv: argv} do
      sid = host_session!(ws)
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat/#{sid}")
      assert is_nil(lv_assigns(tab)[:session]), "the precondition: offline"

      html = render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      render_change(element(tab, "form[phx-change=set-model]"), %{"model" => "opus"})

      args = operator_turn_argv!(op, sid, argv)
      assert {flag(args, "--permission-mode"), flag(args, "--model")} == {"plan", nil}

      assert html =~ refusal()
      assert lv_assigns(tab)[:mode] == "plan"
    end

    test "a tab that opened offline saves nothing once the runtime is up elsewhere",
         %{conn: conn, default_ws: ws} do
      sid = host_session!(ws)
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat/#{sid}")

      {:ok, recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
      assert {:ok, pid} = Recorder.session_pid(recorder)
      assert is_pid(pid), "the precondition: a live runtime"
      assert is_nil(lv_assigns(tab)[:session]), "the precondition: the tab holds no pid"

      html = render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      render_change(element(tab, "form[phx-change=set-model]"), %{"model" => "opus"})

      assert {row(sid).mode, row(sid).model_choice} == {"plan", nil}
      assert html =~ refusal()
    end
  end

  describe "CONTROLS: legit saves keep working" do
    test "the operator's PATCH on an offline session saves, and the next turn spawns with it",
         %{default_ws: ws, op: op, argv: argv} do
      sid = host_session!(ws)

      assert patch_session(op, sid, %{mode: "acceptEdits", model_choice: "opus"}).status == 200
      args = operator_turn_argv!(op, sid, argv)
      assert {flag(args, "--permission-mode"), flag(args, "--model")} == {"acceptEdits", "opus"}
    end

    test "a non-operator's echo, draft and effort still save (none reach the spawn's mode)",
         %{default_ws: ws, seat: seat} do
      sid = host_session!(ws)

      assert patch_session(seat, sid, %{mode: "plan", draft: "leave echo"}).status == 200
      assert patch_session(seat, sid, %{effort_choice: "high"}).status == 200

      assert {row(sid).mode, row(sid).draft, row(sid).effort_choice} ==
               {"plan", "leave echo", "high"}
    end

    test "an operator tab on an offline session saves the mode and model",
         %{conn: conn, default_ws: ws, op: op} do
      sid = host_session!(ws)
      tab = mount_token(conn, op, "/studio/chat/#{sid}")

      html = render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      render_change(element(tab, "form[phx-change=set-model]"), %{"model" => "opus"})

      assert {row(sid).mode, row(sid).model_choice} == {"acceptEdits", "opus"}
      refute html =~ refusal()
    end

    test "with no allowlist, a Default admin tab saves the mode", %{conn: conn, default_ws: ws} do
      Application.put_env(:barkpark, :operator_token_ids, [])
      sid = host_session!(ws)
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat/#{sid}")

      refute render_hook(tab, "set-mode", %{"mode" => "acceptEdits"}) =~ refusal()
      assert row(sid).mode == "acceptEdits"
    end

    test "a brand-new tab (no row yet) still picks its first mode and model",
         %{conn: conn, default_ws: ws} do
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat")
      assert is_nil(lv_assigns(tab)[:store_session_id]), "the precondition: no row"

      html = render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      render_change(element(tab, "form[phx-change=set-model]"), %{"model" => "opus"})

      refute html =~ refusal()
      assert {lv_assigns(tab)[:mode], lv_assigns(tab)[:model_choice]} == {"acceptEdits", "opus"}
    end
  end

  # task-7321bf17168e60ff: a NEW session's first mode and model are saved
  # settings too. A principal refused the host turn may not leave a host-exec
  # row carrying them for the operator's next turn to spawn from.
  describe "allowlist armed: a refused principal's new session carries no mode or model" do
    test "a brand-new tab's refused first send leaves no row the operator's turn spawns from",
         %{conn: conn, default_ws: ws, op: op, argv: argv} do
      before = row_ids()
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat")
      render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      render_change(element(tab, "form[phx-change=set-model]"), %{"model" => "opus"})

      html = send_from(tab, "seat turn")

      spawned = operator_spawns(op, row_ids() -- before, argv)

      assert spawned == [],
             "the refused tab left a row the operator's next turn spawned with #{inspect(spawned)}"

      assert html =~ refusal()
      assert {lv_assigns(tab)[:session], lv_assigns(tab)[:store_session_id]} == {nil, nil}
    end

    test "POST /v1/chat/sessions with a mode or model is refused and leaves no row",
         %{op: op, seat: seat, argv: argv} do
      before = row_ids()
      mode = create_session(seat, %{mode: "acceptEdits"})
      model = create_session(seat, %{model: "opus"})

      spawned = operator_spawns(op, row_ids() -- before, argv)

      assert spawned == [],
             "the seat's create left rows the operator's next turn spawned with #{inspect(spawned)}"

      assert refused?(mode), "mode create answered #{mode.status}, the turn door is 403"
      assert refused?(model), "model create answered #{model.status}, the turn door is 403"
    end
  end

  describe "CONTROLS: legit new sessions keep their first mode and model" do
    test "an operator's new tab spawns with the mode it picked",
         %{conn: conn, default_ws: ws, argv: argv} do
      # A Default-bound operator: the flat tab creates in the workspace its
      # principal is authorized in, and an unbound token is authorized nowhere.
      raw = "savedmode-optab-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "op tab", "production", ["admin"], ws.id)
      Application.put_env(:barkpark, :operator_token_ids, [token.id])

      tab = mount_token(conn, raw, "/studio/chat")
      render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      refute send_from(tab, "operator turn") =~ refusal()

      assert row(lv_assigns(tab)[:store_session_id]).mode == "acceptEdits"
      assert argv |> await_argv() |> flag("--permission-mode") == "acceptEdits"
    end

    test "with no allowlist, a Default admin's new tab spawns with the mode it picked",
         %{conn: conn, default_ws: ws, argv: argv} do
      Application.put_env(:barkpark, :operator_token_ids, [])
      tab = mount_user(conn, default_admin_user!(ws), "/studio/chat")
      render_hook(tab, "set-mode", %{"mode" => "acceptEdits"})
      refute send_from(tab, "admin turn") =~ refusal()

      assert row(lv_assigns(tab)[:store_session_id]).mode == "acceptEdits"
      assert argv |> await_argv() |> flag("--permission-mode") == "acceptEdits"
    end

    test "the operator's create keeps its mode and model, and the next turn spawns with them",
         %{op: op, argv: argv} do
      resp = create_session(op, %{mode: "acceptEdits", model: "opus"})
      assert resp.status == 201, "#{resp.status} #{resp.resp_body}"

      assert operator_spawns(op, [json_response(resp, 201)["id"]], argv) ==
               [{"acceptEdits", "opus"}]
    end

    test "a non-operator still creates: the defaults, a registered host, no allowlist, cloud",
         %{default_ws: ws, seat: seat} do
      host = %{
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: Ecto.UUID.generate(),
        mode: "acceptEdits"
      }

      assert create_session(seat, %{}).status == 201
      assert create_session(seat, %{mode: "plan"}).status == 201
      assert create_session(seat, host).status == 201

      {:ok, _} = Tenancy.set_workspace_chat_settings(ws.id, %{"execution_profile" => "cloud"})
      assert create_session(seat, %{mode: "acceptEdits", model: "opus"}).status == 201

      {:ok, _} = Tenancy.set_workspace_chat_settings(ws.id, %{})
      Application.put_env(:barkpark, :operator_token_ids, [])
      assert create_session(seat, %{mode: "acceptEdits", model: "opus"}).status == 201
    end
  end
end
