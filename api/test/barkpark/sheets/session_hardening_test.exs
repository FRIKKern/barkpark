defmodule Barkpark.Plugins.Sheets.SessionHardeningTest.HaltingPersist do
  @moduledoc false
  # A before_save hook that halts ONLY the sheets-session persist path
  # (ctx.source == "sheets_session"). Installed via the `:barkpark, :plugins`
  # application-env seam for the duration of a test, so the canonical
  # `Content.upsert_document/4` returns `{:error, {:halted, _}}` exactly like
  # a real plugin gate refusing the write — a genuine persist failure, no
  # mocking of the session internals.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt_session_persist/1]}

  def halt_session_persist(%{ctx: %{source: "sheets_session"}}),
    do: {:halt, "forced persist failure (test)"}

  def halt_session_persist(_payload), do: :ok
end

defmodule Barkpark.Plugins.Sheets.SessionHardeningTest do
  @moduledoc """
  Review-phase locks for `Barkpark.Plugins.Sheets.Session` — the verified-but-deferred
  minors:

    1. `flush/2` surfaces a failed persist as `{:error, reason}` instead of a
       silent `:ok` (read-your-writes must never serve the stale row as
       fresh); the state stays dirty and the debounce retry stays armed.
    2. `call_session/4` retries a dead session exactly ONCE — a second death
       in the window returns `{:error, :session_unavailable}` rather than
       propagating the raw exit to the caller.
    3. `apply_ops/3` refuses batches over `max_ops_per_call/0` outright
       (`{:error, :batch_too_large, n}`), before the call reaches a session.

  `async: false` — sessions are globally registered processes that read and
  persist through the SQL sandbox (shared mode), and the timing knobs plus
  the `:plugins` hook seam go through the global `Application` env.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.SessionHardeningTest.HaltingPersist

  @dataset "sheets_hardening_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])
    Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session, Keyword.merge(base, overrides))
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp create_sheet(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "T0", "cells" => cells}]}},
        @dataset
      )

    doc
  end

  defp set_cell(ref, raw), do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw}

  defp persisted_cell(slug, ref) do
    {:ok, doc} = Content.get_document(Content.draft_id(slug), "sheet", @dataset)
    get_in(doc.content, ["tabs", Access.at(0), "cells", ref])
  end

  defp wait_until(fun, timeout \\ 2_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met within the wait window")
      else
        Process.sleep(20)
        do_wait_until(fun, deadline)
      end
    end
  end

  # Install/remove the halting before_save hook through the `:plugins` env
  # seam (unset in test config, so Hooks falls back to the Registry; setting
  # it makes our module the sole hook source for the window).
  defp with_failing_persist(fun) do
    prior = Application.fetch_env(:barkpark, :plugins)
    Application.put_env(:barkpark, :plugins, [HaltingPersist])

    try do
      fun.()
    after
      case prior do
        {:ok, v} -> Application.put_env(:barkpark, :plugins, v)
        :error -> Application.delete_env(:barkpark, :plugins)
      end
    end
  end

  # ── 1. flush surfaces a failed persist ─────────────────────────────────────

  describe "flush on a failed persist" do
    test "replies {:error, reason}, keeps the state dirty, and the armed debounce retry persists once the failure clears" do
      create_sheet("hd-flush", %{"A1" => %{"v" => "stale"}})
      put_cfg(debounce_ms: 100)

      log =
        capture_log(fn ->
          with_failing_persist(fn ->
            {:ok, %{applied: 1}} = Session.apply_ops("hd-flush", @dataset, [set_cell("A1", "fresh")])

            # The flush must NOT read as :ok — the persisted row is stale.
            assert {:error, {:halted, "forced persist failure (test)"}} =
                     Session.flush("hd-flush", @dataset)

            assert persisted_cell("hd-flush", "A1") == %{"v" => "stale"}

            # The session's memory stays authoritative (dirty, not dropped).
            assert {:ok, content} = Session.peek("hd-flush", @dataset)
            assert get_in(content, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => "fresh"}
          end)

          # The failure window closed; the debounce retry the FAILED flush
          # re-armed persists on its own — no second explicit flush.
          wait_until(fn -> persisted_cell("hd-flush", "A1") == %{"v" => "fresh"} end)
        end)

      assert log =~ "persist failed"
    end

    test "a clean flush still replies :ok (no session, clean session, dirty session)" do
      assert Session.flush("hd-no-session", @dataset) == :ok

      create_sheet("hd-clean", %{})
      {:ok, _} = Session.apply_ops("hd-clean", @dataset, [set_cell("A1", 1)])
      assert Session.flush("hd-clean", @dataset) == :ok
      # Idempotent: a second flush on the now-clean state is a no-op :ok.
      assert Session.flush("hd-clean", @dataset) == :ok
      assert persisted_cell("hd-clean", "A1") == %{"v" => 1}
    end
  end

  # ── 2. bounded session-death retry ─────────────────────────────────────────

  describe "call_session retry bound" do
    test "a session dying twice in the call window yields {:error, :session_unavailable}, not a raw exit" do
      create_sheet("hd-dead", %{})
      {:ok, _} = Session.apply_ops("hd-dead", @dataset, [set_cell("A1", 1)])
      pid = Session.whereis("hd-dead", @dataset)
      assert is_pid(pid)

      # Suspend the registry partition so the dead session's entry cannot be
      # cleaned up: BOTH the call and its single retry deterministically meet
      # the stale pid (:noproc) — the exact double-death window. Before the
      # bound, the second :noproc propagated as a raw exit to the caller.
      partitions = registry_partitions()
      Enum.each(partitions, &:sys.suspend/1)

      try do
        GenServer.stop(pid, :normal, 5_000)

        assert {:error, :session_unavailable} =
                 Session.apply_ops("hd-dead", @dataset, [set_cell("A1", 2)])
      after
        Enum.each(partitions, &:sys.resume/1)
      end

      # Transient by construction: once the registry catches up, the next
      # call starts a fresh session (state reloaded from the persisted row).
      wait_until(fn -> Session.whereis("hd-dead", @dataset) == nil end)
      assert {:ok, %{applied: 1}} = Session.apply_ops("hd-dead", @dataset, [set_cell("A1", 3)])
    end
  end

  # The registry's partition workers — suspending them delays dead-pid
  # cleanup, which is exactly the lookup↔call race the retry bound guards.
  defp registry_partitions do
    Barkpark.Plugins.Sheets.SessionRegistry
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  # ── 3. per-call batch bound ────────────────────────────────────────────────

  describe "apply_ops batch cap" do
    test "a batch over max_ops_per_call is refused before any session starts" do
      create_sheet("hd-batch", %{})
      n = Session.max_ops_per_call() + 1
      ops = for i <- 1..n, do: set_cell("A#{i}", i)

      assert {:error, :batch_too_large, ^n} = Session.apply_ops("hd-batch", @dataset, ops)
      # Refused pre-mailbox: the oversized call never started a session.
      assert Session.whereis("hd-batch", @dataset) == nil
    end

    test "a batch exactly at the cap applies whole" do
      create_sheet("hd-batch-cap", %{})
      cap = Session.max_ops_per_call()
      ops = for i <- 1..cap, do: set_cell("A#{i}", i)

      assert {:ok, %{applied: ^cap, errors: []}} =
               Session.apply_ops("hd-batch-cap", @dataset, ops)

      assert {:ok, content} = Session.peek("hd-batch-cap", @dataset)
      assert map_size(get_in(content, ["tabs", Access.at(0), "cells"])) == cap
    end
  end
end
