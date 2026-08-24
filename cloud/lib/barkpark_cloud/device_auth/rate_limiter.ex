defmodule BarkparkCloud.DeviceAuth.RateLimiter do
  @moduledoc """
  A fixed-window rate limiter for the device-authorization endpoints
  (bp-login-ux), the sibling of `Accounts.TwoFactorRateLimiter` — the same
  GenServer-owns-one-public-ETS-table shape, but its OWN table (the key shapes
  differ, so they must not share) and a GENERIC `check/1` keyed by an arbitrary
  string. The per-action limit is chosen by the key's `"<action>:"` prefix
  (charter decision 8):

    * `"poll:"<device_code_hash>` — 20 / 60s. The CLI polls every 5s; 20/min
      leaves generous headroom while capping a runaway loop. The router maps the
      breach to `429 {"error":"slow_down"}` (RFC-8628 back-off signal).
    * `"start:"<peer_ip>`  — 10 / 60s. Caps device-request creation per IP.
    * `"approve:"<user_id>` — 10 / 60s. Caps approve/deny/inspect attempts per
      authenticated user, so an authed attacker can't brute the ~39-bit user_code
      within its 600s TTL.
    * `"app_token:"<peer_ip>` — 10 / 60s. Caps app-token exchange mints per IP
      (`POST /v1/barkparks/:id/app-token`) — each hit costs the instance a
      server-side admin-authed mint call, so a runaway client must be braked
      here, before the proxy fans out.
    * `"app_token_revoke:"<peer_ip>` — 10 / 60s. The mint bucket's revoke twin
      (`DELETE /v1/barkparks/:id/app-token`, mob-w2-app-token-revoke) — same
      physics (every hit is a server-side admin-authed instance call), its own
      bucket so a logout loop can't starve mints and vice versa.
    * `"push_register:"<user_id>` — 10 / 60s. Caps device-push-token
      registrations (`POST /v1/push/device-tokens`, mob-bl-push-hardening) per
      authenticated USER, not per IP — the route is user-authed and mobile
      clients share carrier-NAT IPs, so a per-IP bucket would let one user
      starve strangers. The app registers once per launch; 10/min brakes a
      runaway loop without touching real use. Pairs with the per-user
      device-row cap in `Push.register_device_token/2`.
    * `"register:"<peer_ip>` — 30 / 60s, on `POST /v1/auth/register`
      (arpss wave 3). Caps account-creation writes per IP — each hit is an
      unauthenticated Repo.transaction that mints a user + team + membership +
      trial. NOTE the DISTINCT prefix: `"register:"` is the unauth signup
      bucket, `"push_register:"` above is the AUTHED device-push bucket — same
      word, different physics, so they must never share a key. Per-IP (not
      per-user) because there is no session yet to key on, and 30 (not the
      @default_limit of 10) for the same corporate-NAT-headroom reason as
      `oauth_exchange` below: a whole office signs up from one NAT'd IP on the
      last hop.

  The key is `{key_string, window}` where `window = div(now_ms, @window_ms)`, so
  strictly-elapsed windows are lazily swept on the next `check/1` for that key.
  That sweep is PER-KEY: its match head pins the key being checked, so it bounds
  how many rows ONE key accrues — to one, or transiently two while a straddling
  caller's older window sits beside a newer one, collapsing back to one on that
  key's next forward call — and nothing more. `check/1` is the only mutation;
  `reset/0` clears the table for deterministic tests.

  ## The table is bounded by a SWEEP, because the per-key sweep is not a bound

  The per-key sweep only bounds keys that RECUR (acpc-bl-poll-key-unbounded-ets-
  growth). The `"poll:"` bucket does not: `POST /v1/auth/device/poll` calls
  `check("poll:" <> DeviceAuth.device_code_hash(device_code))` BEFORE
  `DeviceAuth.poll/1` validates the code, and `device_code_hash/1` is
  `UserToken.hash_token/1` — a pure hash of the caller's bytes. So an
  unauthenticated caller posting random `device_code` values minted one row that
  nothing ever swept: a measured 152 bytes each, ~7.06M distinct keys per GiB,
  ~13 GB/day at 1000 req/s. The route is pre-session and this limiter IS the
  first gate, so nothing braked the minting. That is an availability defect, not
  an over-admission one — every counter was correct.

  `poll:` is the ONLY attacker-chosen key space of the eight prefixes.
  `start:`/`register:`/`oauth_exchange:`/`app_token:`/`app_token_revoke:` key on
  `peer_ip`, which RemoteIp resolves from the RIGHTMOST trusted-proxy hop and is
  therefore not caller-controlled; `approve:`/`push_register:` key on an
  authenticated user id. Those leak one permanent row per one-shot source IP or
  user — the same shape, bounded by a far smaller space.

  So `maybe_prune/1` adds a GLOBAL sweep: at most once per window, one caller
  claims the sweep and deletes EVERY key's elapsed rows, not just its own. The
  table is bounded by `@prune_floor` plus the distinct keys arriving inside one
  60s window — ~60k rows (~9 MB) at 1000 req/s, against a previously unbounded
  13 GB/day.

  WHY IN-BAND AND NOT A TIMER. Oban is the only scheduler in this plane and
  `promise_actor_manifest_test.exs` gates that with a SOURCE GREP over
  `cloud/lib` for process-send-after / timer-interval / Quantum / Crontab
  arming. (That grep reads prose too, so this paragraph deliberately spells none
  of those out.) An Oban job would be wrong on its
  own terms anyway — this table is per-NODE process memory, so a job that runs
  on one node cannot prune another's. Sweeping while a caller is already here is
  the shape `Registry.AgentKeyStash.put/3` established for exactly this reason.

  WHY THE SWEEP IS CLAIMED. A naive "sweep whenever the table is large" makes
  every request past the threshold pay an O(n) scan — a CPU amplifier strictly
  worse than the memory it reclaims. The claim key `{:__prune__, window}` is
  taken with `:ets.insert_new/2`, which is atomic, so exactly ONE caller per
  window scans and the rest do a single failed insert. The marker is a 2-tuple
  keyed on an ATOM, so it can never collide with a real key (always a binary),
  and it matches the sweep's own match head — the previous window's marker is
  deleted by the next window's sweep, so the bookkeeping cleans itself up.

  This is a bound, not a mitigation. The pre-existing "every container restart
  clears it" (~23 cp deploys/day) was a mitigation, and it is not one this module
  may rely on.
  """
  use GenServer

  @table __MODULE__
  @window_ms 60_000
  @default_limit 10
  # Below this the table is trivially small and the global sweep is not worth
  # the `insert_new` it costs; the per-key sweep already keeps every recurring
  # key at one row. Chosen well above any legitimate concurrent-caller count and
  # far below the point where a full scan is noticeable.
  @prune_floor 256
  @limits %{
    "poll" => 20,
    "start" => 10,
    "approve" => 10,
    "app_token" => 10,
    "app_token_revoke" => 10,
    "push_register" => 10,
    "register" => 30,
    # cch-w10: `"oauth_exchange:"<peer_ip>` — 30 / 60s, on `POST
    # /v1/auth/oauth/exchange`. An EXPLICIT entry, not the @default_limit of 10,
    # and the reason is the one push_register above documents from the other side:
    # this bucket is per-IP because there is no session yet to key on, and a whole
    # office behind one corporate NAT shares that IP on the LAST hop of their
    # sign-in. 10/min would starve them. 30 is still a hard bound on guessing a
    # 256-bit code — the code's own 120s TTL and burn-on-use do the real work.
    "oauth_exchange" => 30
  }

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Record one hit against `key` and enforce its window limit. Returns `:ok` while
  at or under the limit for the key's action prefix, `{:error, :rate_limited}`
  once exceeded. The window is #{div(@window_ms, 1000)}s.
  """
  @spec check(binary(), integer()) :: :ok | {:error, :rate_limited}
  def check(key, now_ms \\ System.system_time(:millisecond))

  def check(key, now_ms) when is_binary(key) and is_integer(now_ms) do
    limit = limit_for(key)
    window = div(now_ms, @window_ms)

    # Drop this key's rows from any earlier window. This bounds ONE key; it is
    # not a bound on the table (see the moduledoc) — `maybe_prune/1` is.
    :ets.select_delete(@table, [
      {{{key, :"$1"}, :_}, [{:<, :"$1", window}], [true]}
    ])

    maybe_prune(window)

    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0})

    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  # THE GLOBAL SWEEP, at most once per window. `:ets.info(:size)` is O(1), so a
  # small table pays one integer compare and nothing else. Above the floor, the
  # atomic `insert_new/2` elects exactly one caller per window to pay the scan —
  # every other caller pays one failed insert. The `:"$1"` guard deletes only
  # STRICTLY earlier windows, so a concurrent caller's current counter is never
  # reset by the sweep and handed a fresh budget.
  defp maybe_prune(window) do
    if :ets.info(@table, :size) > @prune_floor and
         :ets.insert_new(@table, {{:__prune__, window}, 0}) do
      :ets.select_delete(@table, [
        {{{:_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}
      ])
    end

    :ok
  end

  @doc "Clear all counters (test helper — keeps async: false rate-limit tests deterministic)."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp limit_for(key) do
    action = key |> String.split(":", parts: 2) |> hd()
    Map.get(@limits, action, @default_limit)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end
end
