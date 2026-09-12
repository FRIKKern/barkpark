defmodule Barkpark.Quiz.SpawnBudgetTest do
  @moduledoc """
  The per-principal brake in front of `Quiz.RoomSupervisor`'s global cap.

  Every test here sets a SMALL `:per_hour` for the duration — the point is the
  refusal, not the number — and every assertion names the principal it is
  billing, because a budget that cannot tell two visitors apart is a global cap
  wearing a different hat (which is precisely what this slice replaced).

  `async: false`: `Barkpark.RateLimiter` is one `:named_table` for the whole
  node and these tests mutate `:barkpark, :quiz_room_spawn` application env.
  Bucket keys are still per-principal AND per-test-process scoped (each conn
  comes from `ConnCase.scoped_conn/0`), so nothing here bills a sibling module.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.Quiz
  alias Barkpark.Quiz.{Room, SpawnBudget}

  # `:barkpark_rate_limiter` is a :named_table — whole-node state no sandbox
  # rolls back. Without this every budget assertion here inherits whatever
  # earlier files spent. Safe only because this module is `async: false`, which
  # `RateLimiterAsyncIsolationTest` pins.
  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :quiz_room_spawn)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :quiz_room_spawn)
        opts -> Application.put_env(:barkpark, :quiz_room_spawn, opts)
      end
    end)

    :ok
  end

  defp budget(opts), do: Application.put_env(:barkpark, :quiz_room_spawn, opts)

  defp pin, do: "SB" <> Integer.to_string(System.unique_integer([:positive]))

  # A conn carrying BOTH a distinct client address and this test process's
  # rate-limit scope — the two halves of a bucket key that means something.
  defp visitor(address) do
    %{scoped_conn() | remote_ip: address}
  end

  defp open_rooms(source, n) do
    for _ <- 1..n do
      p = pin()
      on_exit(fn -> Quiz.stop_room(p) end)
      Room.ensure(p, source)
    end
  end

  describe "the budget refuses, and the refusal is the visitor's not the service's" do
    test "an over-budget spawn is refused where an in-budget one succeeds" do
      budget(per_hour: 2)
      who = visitor({203, 0, 113, 11})

      assert [{:ok, first}, {:ok, second}] = open_rooms(who, 2)
      assert is_pid(first) and is_pid(second)

      # WITHOUT the budget this third call returns {:ok, pid} — the global
      # max_children cap (10_000) is nowhere near, so nothing else in the tree
      # can produce a refusal here.
      refused = pin()
      on_exit(fn -> Quiz.stop_room(refused) end)

      assert Room.ensure(refused, who) == {:error, :spawn_budget}
      assert Room.whereis(refused) == nil, "a refused spawn must not have started a room"
    end

    test "a DIFFERENT principal is untouched by the first one's exhausted budget" do
      budget(per_hour: 1)

      greedy = visitor({203, 0, 113, 12})
      bystander = visitor({203, 0, 113, 13})

      assert [{:ok, _}] = open_rooms(greedy, 1)
      assert Room.ensure(pin(), greedy) == {:error, :spawn_budget}

      # THE WHOLE POINT of a per-IP budget over a global cap: the second
      # visitor still gets a room. Under the old bare max_children brake this
      # distinction did not exist.
      p = pin()
      on_exit(fn -> Quiz.stop_room(p) end)
      assert {:ok, pid} = Room.ensure(p, bystander)
      assert is_pid(pid)
    end

    test "resolving an ALREADY-LIVE room never spends budget" do
      budget(per_hour: 1)
      who = visitor({203, 0, 113, 14})

      p = pin()
      on_exit(fn -> Quiz.stop_room(p) end)
      assert {:ok, pid} = Room.ensure(p, who)

      # The host refreshing the projector, reconnecting, or opening a second
      # screen on ITS OWN pin: registry hit, no debit. Ten of them.
      for _ <- 1..10, do: assert(Room.ensure(p, who) == {:ok, pid})

      # Budget of 1 is spent by the FIRST spawn only, so a NEW pin still refuses
      # — proving the ten no-ops were free rather than the budget being off.
      assert Room.ensure(pin(), who) == {:error, :spawn_budget}
    end
  end

  describe "who lands in the fallback bucket" do
    test "a source-less LiveView mount bills the shared fallback principal" do
      budget(per_hour: 1)

      assert SpawnBudget.principal(nil) == :fallback

      # nil is what `QuizHostLive`'s connect_info read degrades to if a
      # transport ever stops carrying one. Metered, not exempt: an
      # unattributable spawn through a REACHABLE door is the spawn that should
      # be scarce.
      p = pin()
      on_exit(fn -> Quiz.stop_room(p) end)
      assert {:ok, _} = Room.ensure(p, nil)

      assert Room.ensure(pin(), nil) == {:error, :spawn_budget}
    end

    test "ensure/1 is the INTERNAL form and spends no budget" do
      budget(per_hour: 1)
      assert SpawnBudget.principal(:internal) == :internal

      for _ <- 1..5 do
        p = pin()
        on_exit(fn -> Quiz.stop_room(p) end)
        assert {:ok, pid} = Quiz.ensure_room(p)
        assert is_pid(pid)
      end
    end

    test "NO REACHABLE DOOR IN lib/ USES THE UNMETERED ARITY-1 FORM" do
      # The tripwire that makes the `:internal` exemption safe. A predicate,
      # not a snapshot: it fails on a call site that does not exist yet, which
      # is the only kind that can quietly reintroduce the bypass.
      #
      # Definitions and delegates are where the arity-1 form is SUPPOSED to
      # appear, so they are matched by shape (`def `/`defdelegate `), never by
      # filename.
      offenders =
        Path.wildcard(Path.join([File.cwd!(), "lib", "**", "*.ex"]))
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            Regex.match?(~r/(Room\.ensure|ensure_room)\(/, line) and
              not Regex.match?(~r/^\s*(#|def |defdelegate |@)/, line) and
              not Regex.match?(~r/(Room\.ensure|ensure_room)\([^()]*,/, line)
          end)
          |> Enum.map(fn {line, n} ->
            Path.relative_to(path, File.cwd!()) <> ":#{n}: " <> String.trim(line)
          end)
        end)

      assert offenders == [],
             """
             These call `Room.ensure/1` / `Quiz.ensure_room/1`, which spends NO
             spawn budget. If any of them is reachable by a visitor, the
             per-principal brake has a bypass. Pass the caller's transport
             context (a %Plug.Conn{} or the socket connect_info) as a second
             argument.

             #{Enum.join(offenders, "\n")}
             """
    end

    test "a connect_info map WITHOUT :peer_data falls back; WITH it resolves an address" do
      assert SpawnBudget.principal(%{}) == :fallback
      assert SpawnBudget.principal(%{x_headers: [{"x-forwarded-for", "9.9.9.9"}]}) == :fallback

      assert SpawnBudget.principal(%{peer_data: %{address: {198, 51, 100, 4}}}) ==
               {:client_ip, "198.51.100.4"}
    end

    test "the forwarded chain is NOT believed from an untrusted peer" do
      # The trust boundary has one owner (`RateLimiter.client_ip/1`); this
      # asserts the budget actually routes through it rather than reading the
      # header itself. A visitor that could pick its own bucket key has no
      # budget at all.
      assert SpawnBudget.principal(%{
               peer_data: %{address: {198, 51, 100, 4}},
               x_headers: [{"x-forwarded-for", "9.9.9.9"}]
             }) == {:client_ip, "198.51.100.4"}
    end
  end

  describe "refusals are counted, never silently dropped" do
    test "an enforced refusal emits the room_spawn refused counter" do
      budget(per_hour: 1)
      who = visitor({203, 0, 113, 15})

      handler = "spawn-budget-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        SpawnBudget.telemetry_event(),
        fn event, measurements, metadata, _ ->
          send(parent, {:metered, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert [{:ok, _}] = open_rooms(who, 1)
      refute_received {:metered, _, _, _}, "an ADMITTED spawn must not count as a refusal"

      assert Room.ensure(pin(), who) == {:error, :spawn_budget}

      assert_received {:metered, [:barkpark, :quiz, :room_spawn, :refused], %{count: 1},
                       %{mode: :enforce, principal_source: :client_ip}}
    end

    test "a SHADOWED refusal is counted AND admitted" do
      budget(per_hour: 1, mode: :shadow)
      who = visitor({203, 0, 113, 16})

      handler = "spawn-budget-shadow-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        SpawnBudget.telemetry_event(),
        fn event, measurements, metadata, _ ->
          send(parent, {:metered, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert [{:ok, _}] = open_rooms(who, 1)

      p = pin()
      on_exit(fn -> Quiz.stop_room(p) end)

      assert {:ok, pid} = Room.ensure(p, who)
      assert is_pid(pid)

      assert_received {:metered, [:barkpark, :quiz, :room_spawn, :refused], %{count: 1},
                       %{mode: :shadow}}
    end
  end

  describe "the kill switch" do
    test "mode: :off consults no bucket at all" do
      budget(per_hour: 1, mode: :off)
      who = visitor({203, 0, 113, 17})

      for {:ok, pid} <- open_rooms(who, 5), do: assert(is_pid(pid))
    end
  end

  describe "configuration" do
    test "defaults hold when nothing is configured" do
      Application.delete_env(:barkpark, :quiz_room_spawn)
      assert SpawnBudget.mode() == :enforce
      assert SpawnBudget.per_hour() == 10
    end

    test "per_hour can never be talked below 1" do
      budget(per_hour: 0)
      assert SpawnBudget.per_hour() == 1
    end

    test "an unrecognised mode fails CLOSED (enforcing), never open" do
      budget(mode: :nonsense)
      assert SpawnBudget.mode() == :enforce
    end
  end
end
