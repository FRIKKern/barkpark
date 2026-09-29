defmodule BarkparkWeb.WriteAdmissionLiveTest do
  # C083: events on a mounted admin LiveView are refused while the instance is held.
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission

  defmodule ProbeLive do
    use Phoenix.LiveView
    import Plug.Conn, except: [assign: 3]
    on_mount({BarkparkWeb.WriteAdmissionLive, :refuse_while_held})

    def mount(_params, _session, socket),
      do: {:ok, Phoenix.Component.assign(socket, :writes, 0)}

    def handle_event("write", _params, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :writes, socket.assigns.writes + 1)}

    def render(assigns) do
      ~H"""
      <button id="write" phx-click="write">write</button>
      <span id="writes">{@writes}</span>
      <p :if={Phoenix.Flash.get(@flash, :error)} id="flash">{Phoenix.Flash.get(@flash, :error)}</p>
      """
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-lv-refusal-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "lv-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate}
  end

  test "an event on a mounted view is halted with a flash while held and runs after reopen", %{
    conn: conn,
    gate: gate
  } do
    {:ok, view, _html} = live_isolated(conn, ProbeLive)
    assert render_click(view, "write") =~ ~s(<span id="writes">1</span>)

    hold = hold(gate)
    html = render_click(view, "write")
    assert html =~ ~s(<span id="writes">1</span>)
    assert html =~ BarkparkWeb.WriteAdmissionLive.message()
    assert Admission.status(gate).phase == :held

    release(gate, hold)
    assert render_click(view, "write") =~ ~s(<span id="writes">2</span>)
    assert Admission.status(gate).pending == 0
  end

  test "the hook is inert when admission is disabled", %{conn: conn} do
    Application.put_env(:barkpark, :write_admission, enabled: false)
    {:ok, view, _html} = live_isolated(conn, ProbeLive)
    assert render_click(view, "write") =~ ~s(<span id="writes">1</span>)
  end

  test "every admin, ops and scoped-admin live session carries the hook" do
    source = File.read!(Path.expand("../../lib/barkpark_web/router.ex", __DIR__))

    gates =
      Regex.scan(
        ~r/\{BarkparkWeb\.LiveAuth, :(admin|ops|scoped_admin)\},\n(\s*)(\{[^\n]*\})/,
        source
      )

    assert length(gates) == 8

    assert Enum.all?(gates, fn [_, _, _, next] ->
             next == "{BarkparkWeb.WriteAdmissionLive, :refuse_while_held}"
           end)
  end

  # The test process owns the hold. begin_hold/reopen are synchronous calls
  # that journal to DETS before replying; a spawned holder re-published those
  # replies as messages raced against assert_receive's 100ms default, which
  # CI load outran (main run 36574063509, task-5381a4e7a1724185). The owner
  # only needs to be a live non-writer: the test process holds no admission
  # while the hold begins, and nothing it spawns inherits the hold.
  defp hold(gate) do
    assert {:ok, :held, ticket} =
             Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

    ticket
  end

  defp release(gate, ticket), do: assert(Admission.reopen(gate, ticket) == :ok)
end
