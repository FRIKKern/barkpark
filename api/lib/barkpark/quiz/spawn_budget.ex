defmodule Barkpark.Quiz.SpawnBudget do
  @moduledoc """
  THE PER-PRINCIPAL BRAKE ON QUIZ ROOM CREATION.

  `Barkpark.Quiz.Room.ensure/2` is the only path that starts a room, it is
  reached from an ANONYMOUS route (`/quiz/host/:pin`, `auth: :public_root`),
  and the pin is visitor-supplied — so before this module the only thing
  standing between one script and 10,000 live GenServers was
  `Quiz.RoomSupervisor`'s global `max_children`. That cap is shared by
  everybody: the first caller to reach it evicts nobody but denies every
  subsequent HOST in the cluster. A global cap is a memory backstop, not a
  fairness control, and it was doing both jobs.

  This module adds the fairness control in front of it: a per-principal token
  bucket over `Barkpark.RateLimiter`, charged ONLY when a spawn actually
  happens. Resolving an ALREADY-LIVE room is free (the `Registry` hit in
  `Room.ensure/2` short-circuits before the budget is consulted), so a host
  refreshing the projector, reconnecting after a dropped websocket, or opening
  the same pin on a second screen never spends budget. The global cap stays
  exactly where it was, as the LAST brake.

  ## The principal, and who lands in the fallback

  `principal/1` resolves the bucket key through `Barkpark.RateLimiter.client_ip/1`
  (`@canonical capability:rate-limit-client-ip`) — the ONE owner of the
  `x-forwarded-for` trust boundary in this tree. It is never re-implemented
  here: a `%Plug.Conn{}` is handed over as-is, and a socket `connect_info` map
  is narrowed to the two fields that resolver actually reads (`:peer_data` →
  `remote_ip`, `:x_headers` → `req_headers`), exactly as
  `BarkparkWeb.UserSocket` does for its connect budget.

  Everything that cannot produce an address lands on ONE shared `:fallback`
  bucket, and the census of who that is matters more than the happy path:

    * a LiveView mount whose transport did not supply `:peer_data`. The `/live`
      socket now declares `[:peer_data, :x_headers]` for BOTH websocket and
      longpoll, so this is unreachable in production today; it becomes reachable
      again the moment someone trims that list.
    * anything handing over a map with no `:peer_data` key.

  Player-side surfaces are NOT in this census because they cannot spawn at all:
  `QuizChannel.join/3` and `QuizPlayLive.mount/3` resolve through
  `Room.whereis/1`, which never starts a room.

  Because the fallback is ONE bucket, an over-budget fallback caller denies
  every other fallback caller. That is deliberate — a spawn we cannot attribute
  is exactly the spawn that should be scarce — but it is also why the LiveView
  door must keep a real address flowing.

  ## The one thing that is NOT metered, and the rule that keeps it that way

  `Room.ensure/1` (and its `Quiz.ensure_room/1` delegate) passes `:internal`
  and spends no budget. A per-VISITOR budget billed to server-side callers
  would meter the server against itself: whichever internal caller ran first
  would deny the rest, since they all share one unattributable identity.

  That exemption is only safe while no REACHABLE door uses the arity-1 form,
  so it is not left to habit — `Barkpark.Quiz.SpawnBudgetTest` greps `lib/` and
  fails if any call site outside the definitions themselves passes a bare pin.
  A new anonymous door therefore cannot quietly inherit the bypass; it has to
  delete a failing test first.

  ## Mode

  `:enforce` (default) refuses; `:shadow` counts the would-be refusal and lets
  the spawn through (the charter's shadow law for a limiter that has not yet
  earned its promotion); `:off` is the kill switch and consults no bucket.
  Operator-tunable at runtime via `BARKPARK_QUIZ_ROOM_SPAWN_MODE` and
  `BARKPARK_QUIZ_ROOM_SPAWN_PER_HOUR`.

  ## Refusals are counted, never dropped

  Every refusal — enforced or shadowed — emits
  `[:barkpark, :quiz, :room_spawn, :refused]` with a `%{count: 1}` measurement
  and a `Logger.warning` counter line carrying the mode and the principal
  source. A silent refusal would make the limiter unobservable exactly when it
  starts mattering.

  ## Window

  The bucket is `per_hour` tokens refilling at `per_hour / 3600` per second, i.e.
  a full-refill-from-empty of 3600s. `Barkpark.RateLimiter`'s `@stale_after_ms`
  invariant requires the prune cutoff (3_600_000 ms) to be >= the SLOWEST call
  site's full refill; 3600s EQUALS the existing slowest (TicketRateLimit,
  AuthWriteRateLimit), so this call site does not move that constant. Anyone
  widening this window past an hour must widen `@stale_after_ms` with it.
  """

  require Logger

  alias Barkpark.RateLimiter

  @telemetry_event [:barkpark, :quiz, :room_spawn, :refused]

  @default_per_hour 10
  @default_mode :enforce

  @type source :: Plug.Conn.t() | map() | :internal | nil
  @type principal :: {:client_ip, String.t()} | :fallback | :internal

  @doc """
  Admit (or refuse) ONE room spawn for the principal behind `source`.

  `:ok` lets `Room.ensure/2` call `DynamicSupervisor.start_child/2`;
  `{:error, :spawn_budget}` is the polite refusal the host door renders.
  """
  @spec admit(source()) :: :ok | {:error, :spawn_budget}
  # Server-side callers are not visitors — see the moduledoc, and the grep
  # tripwire in the test that keeps a real door from reaching this clause.
  def admit(:internal), do: :ok

  def admit(source) do
    case mode() do
      :off ->
        :ok

      mode ->
        per_hour = per_hour()
        who = principal(source)

        key = RateLimiter.scoped_key(source, {:quiz_room_spawn, bucket_id(who)})

        case RateLimiter.check(key, capacity: per_hour, refill_per_sec: per_hour / 3600) do
          :ok -> :ok
          :rate_limited -> refuse(mode, who, per_hour)
        end
    end
  end

  @doc """
  The principal a spawn is billed to: `{:client_ip, ip}` or `:fallback`.

  See the moduledoc census for who lands on `:fallback` and why that bucket is
  shared.
  """
  @spec principal(source()) :: principal()
  def principal(:internal), do: :internal

  def principal(%Plug.Conn{} = conn), do: {:client_ip, RateLimiter.client_ip(conn)}

  def principal(%{peer_data: %{address: address}} = connect_info) when is_tuple(address) do
    # NOT a re-implementation of the trust boundary — the two fields
    # `RateLimiter.client_ip/1` reads, handed to the canonical resolver. Same
    # shape as `BarkparkWeb.UserSocket`'s connect budget; `:x_headers` arrives
    # lowercased from the transport, which is what `get_req_header/2` expects.
    conn = %Plug.Conn{
      remote_ip: address,
      req_headers: Map.get(connect_info, :x_headers, [])
    }

    {:client_ip, RateLimiter.client_ip(conn)}
  end

  def principal(_), do: :fallback

  @doc "The telemetry event every refusal (enforced or shadowed) emits."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  # ── internals ──────────────────────────────────────────────────────────────

  defp bucket_id({:client_ip, ip}), do: ip
  defp bucket_id(:fallback), do: :fallback

  defp refuse(mode, who, per_hour) do
    source_tag =
      case who do
        {:client_ip, _} -> :client_ip
        :fallback -> :fallback
      end

    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{mode: mode, principal_source: source_tag, per_hour: per_hour}
    )

    Logger.warning(
      "quiz.room_spawn.refused mode=#{mode} principal_source=#{source_tag} per_hour=#{per_hour}"
    )

    case mode do
      :enforce -> {:error, :spawn_budget}
      :shadow -> :ok
    end
  end

  defp config, do: Application.get_env(:barkpark, :quiz_room_spawn, [])

  @doc false
  def per_hour do
    config()
    |> Keyword.get(:per_hour, @default_per_hour)
    |> max(1)
  end

  @doc false
  def mode do
    case Keyword.get(config(), :mode, @default_mode) do
      :shadow -> :shadow
      :off -> :off
      _ -> :enforce
    end
  end
end
