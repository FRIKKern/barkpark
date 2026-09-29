defmodule BarkparkCloud.DeviceAuth do
  @moduledoc """
  The device-authorization context (bp-login-ux) — a Claude-Code-style copy-link
  browser login for `bp`. An RFC-8628-shaped handshake with a two-secret model:

    * `device_code` — a 32-byte CSPRNG url64 string the CLI polls with.
    * `user_code` — a short 8-char code shown `XXXX-XXXX` (CSPRNG over the
      unambiguous alphabet `23456789ABCDEFGHJKMNPQRSTVWXYZ`) the human types into
      the browser to approve.

  Both are stored ONLY as their SHA-256 hex hash (the shared
  `Accounts.UserToken.hash_token/1` scheme); lookups are by hash of the presented
  value. The lifecycle is a `pending → approved` state machine on one
  `device_auth_requests` row:

    1. `start/1` mints both codes, captures the CLI's peer IP + User-Agent, and
       inserts a `pending` row with a 600s TTL.
    2. `inspect/1` (browser, authenticated) reads the pending row for the confirm
       screen — who is asking (client name / IP / UA).
    3. `approve/2` flips `pending → approved` and stamps `user_id`, as a CAS on
       `status` so a second approve no-ops. `deny/1` deletes the row.
    4. `poll/1` (CLI) returns `{:pending}` while pending; once approved it
       CONSUMES the row atomically (a single DELETE, count==1 — mirroring
       `OAuth.consume_state`) and only THEN mints the real session via
       `Accounts.create_user_session_token/2` (with the row's captured IP + UA),
       returning `{:ok, token, team}`. So no session plaintext is ever at rest,
       and a replayed poll finds nothing → `{:error, :expired_or_invalid}`.

  ## Why mint at poll, not approve

  The session is minted at POLL time, not at approve time (charter decision 2).
  Approve, running in the browser, only records intent (`user_id` + `approved`);
  the token materializes on the CLI's next poll, is handed straight to the CLI,
  and never touches the browser. This keeps the poll success envelope
  byte-identical to `POST /v1/auth/login` (`{token, team_id}` with
  `team = Accounts.primary_team(user)`) so CLI storage reuse is trivial.

  ## Team binding (cross-workspace approval)

  `start/1` may name the team the login is FOR (`:team_id`). The row then
  carries `requested_team_id`, and `approve/2` only flips it for a MEMBER of that
  team — the membership test sits inside the same CAS `UPDATE`, so there is no
  check-then-act window. An approver from another team gets
  `{:error, :team_mismatch}` and the row stays `pending` for a rightful
  approver (or a deny). `poll/1` re-checks the membership at mint time (it may
  have been revoked in the ≤600s since approve) and mints THAT team, not the
  approver's primary one. An unbound request (no `:team_id`) keeps the original
  behaviour: any authenticated user may approve their own login.

  ## Expiry

  `expires_at` (600s) is enforced IN-BAND by every query (`expires_at > now`,
  like `oauth.ex`). The `DeviceAuthReaper` Oban worker sweeping expired rows is
  hygiene only — a request past its TTL is already dead to every read here.
  """
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.DeviceAuth.Request
  alias BarkparkCloud.Repo

  # The unambiguous CSPRNG alphabet for the human-typed user_code — no 0/O/1/I/L
  # to fight transcription errors (charter decision 7).
  @user_code_alphabet ~c"23456789ABCDEFGHJKMNPQRSTVWXYZ"
  @user_code_length 8
  @ttl_seconds 600
  @interval_seconds 5
  @max_insert_attempts 3

  @doc "The CLI poll interval, in seconds (RFC-8628 `interval`)."
  @spec interval_seconds() :: pos_integer()
  def interval_seconds, do: @interval_seconds

  @doc "The request TTL, in seconds (RFC-8628 `expires_in`)."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Hash a presented `device_code` for lookup / rate-limit keying. Public so the
  router can key the poll rate limiter on the HASH, keeping the raw device code
  out of the ETS table.
  """
  @spec device_code_hash(binary()) :: String.t()
  def device_code_hash(device_code) when is_binary(device_code),
    do: UserToken.hash_token(device_code)

  @doc """
  Start a device-authorization request.

  `attrs` carries `:client_name`, `:ip_address`, `:user_agent` (all optional,
  captured off the CLI's request) and an optional `:team_id` binding the login
  to one team (see "Team binding"); a `:team_id` that is not the UUID of an
  existing team is `{:error, :invalid_team}`. Mints a fresh `device_code` + `user_code`,
  inserts a `pending` row with a #{@ttl_seconds}s TTL, and returns the PLAINTEXT
  codes (shown once) plus the poll `interval` and `expires_in`:

      {:ok, %{device_code: dc, user_code: "XXXX-XXXX", interval: 5, expires_in: 600}}

  Retries on the (vanishingly unlikely) unique-hash collision before giving up
  with `{:error, changeset}`.
  """
  @spec start(map()) ::
          {:ok,
           %{
             device_code: String.t(),
             user_code: String.t(),
             interval: pos_integer(),
             expires_in: pos_integer()
           }}
          | {:error, :invalid_team}
          | {:error, Ecto.Changeset.t()}
  def start(attrs \\ %{}) do
    case Map.get(attrs, :team_id) do
      blank when blank in [nil, ""] ->
        do_start(Map.put(attrs, :requested_team_id, nil), @max_insert_attempts)

      team_id ->
        case Repo.uuid_or_nil(team_id) do
          nil -> {:error, :invalid_team}
          tid -> do_start(Map.put(attrs, :requested_team_id, tid), @max_insert_attempts)
        end
    end
  end

  defp do_start(attrs, attempts_left) do
    device_code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    user_code = generate_user_code()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, @ttl_seconds, :second)

    result =
      %Request{}
      |> Request.changeset(%{
        device_code_hash: device_code_hash(device_code),
        user_code_hash: user_code_hash(user_code),
        client_name: normalize_client_name(Map.get(attrs, :client_name)),
        ip_address: Map.get(attrs, :ip_address),
        user_agent: Map.get(attrs, :user_agent),
        requested_team_id: Map.get(attrs, :requested_team_id),
        status: "pending",
        expires_at: expires_at
      })
      |> Repo.insert()

    case result do
      {:ok, _row} ->
        {:ok,
         %{
           device_code: device_code,
           user_code: user_code,
           interval: @interval_seconds,
           expires_in: @ttl_seconds
         }}

      {:error, changeset} when attempts_left > 1 ->
        # A unique-hash collision (both codes are CSPRNG, so this is essentially
        # never) — draw fresh codes and retry rather than surface a spurious error.
        cond do
          hash_collision?(changeset) -> do_start(attrs, attempts_left - 1)
          unknown_team?(changeset) -> {:error, :invalid_team}
          true -> {:error, changeset}
        end

      {:error, changeset} ->
        if unknown_team?(changeset), do: {:error, :invalid_team}, else: {:error, changeset}
    end
  end

  @doc """
  Read a still-pending, unexpired request by its `user_code` for the browser
  confirm screen. Returns `{:ok, %Request{}}` or `{:error, :expired_or_invalid}`
  (unknown, already-approved, denied, or expired — the caller must not be able to
  tell which).
  """
  @spec inspect(binary()) :: {:ok, Request.t()} | {:error, :expired_or_invalid}
  def inspect(user_code) when is_binary(user_code) do
    now = DateTime.utc_now()

    query =
      from(r in Request,
        where:
          r.user_code_hash == ^user_code_hash(user_code) and r.status == "pending" and
            r.expires_at > ^now
      )

    case Repo.one(query) do
      %Request{} = row -> {:ok, row}
      nil -> {:error, :expired_or_invalid}
    end
  end

  def inspect(_), do: {:error, :expired_or_invalid}

  @doc """
  Approve a pending request, stamping `user_id`. A CAS on `status`
  (`pending → approved`, unexpired): exactly one row updated → `:ok`; zero rows
  (unknown / already-approved / denied / expired) → `{:error, :expired_or_invalid}`.
  A second approve of the same code therefore fails.

  A TEAM-BOUND request (`requested_team_id` set) only flips for a member of that
  team — the membership subquery is part of the same `UPDATE`. A live, pending
  request refused on that ground answers `{:error, :team_mismatch}` and stays
  pending (nothing is stamped).

  The caller MUST have already authenticated the browser user (the router's
  `Auth.require_user` Bearer gate) — this function trusts `user_id`.
  """
  @spec approve(binary(), binary()) :: :ok | {:error, :expired_or_invalid | :team_mismatch}
  def approve(user_code, user_id) when is_binary(user_code) and is_binary(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = user_code_hash(user_code)

    member_teams = from(m in TeamMembership, where: m.user_id == ^user_id, select: m.team_id)

    {count, _} =
      from(r in Request,
        where:
          r.user_code_hash == ^hash and r.status == "pending" and r.expires_at > ^now and
            (is_nil(r.requested_team_id) or r.requested_team_id in subquery(member_teams))
      )
      |> Repo.update_all(set: [status: "approved", user_id: user_id, updated_at: now])

    cond do
      count == 1 -> :ok
      pending_team_bound?(hash, now) -> {:error, :team_mismatch}
      true -> {:error, :expired_or_invalid}
    end
  end

  def approve(_, _), do: {:error, :expired_or_invalid}

  # After a zero-row approve: was the code live and pending, but bound to a team
  # the approver is not in? Only then is the refusal a team mismatch; every other
  # zero (unknown / approved / expired) stays the undifferentiated 404.
  defp pending_team_bound?(hash, now) do
    Repo.exists?(
      from(r in Request,
        where:
          r.user_code_hash == ^hash and r.status == "pending" and r.expires_at > ^now and
            not is_nil(r.requested_team_id)
      )
    )
  end

  @doc """
  Deny a request: delete the row by `user_code`. Idempotent — always `:ok` (a
  no-op when the code is unknown or already gone). A subsequent poll on the
  matching device code then finds nothing → `{:error, :expired_or_invalid}`.
  """
  @spec deny(binary()) :: :ok
  def deny(user_code) when is_binary(user_code) do
    from(r in Request, where: r.user_code_hash == ^user_code_hash(user_code))
    |> Repo.delete_all()

    :ok
  end

  def deny(_), do: :ok

  @doc """
  Poll a request by its `device_code`.

    * still `pending`          → `{:pending}`
    * `approved`               → CONSUME the row (atomic single DELETE) and mint
      the real session with the row's captured IP + UA → `{:ok, token, team}`
    * expired / denied / gone / replayed → `{:error, :expired_or_invalid}`

  The consume-then-mint order (delete count==1 BEFORE `create_user_session_token`)
  is what makes a replay fail closed: two racing polls, only one deletes the row,
  only one mints.
  """
  @spec poll(binary()) ::
          {:pending} | {:ok, String.t(), map() | nil} | {:error, :expired_or_invalid}
  def poll(device_code) when is_binary(device_code) and device_code != "" do
    now = DateTime.utc_now()

    query =
      from(r in Request,
        where: r.device_code_hash == ^device_code_hash(device_code) and r.expires_at > ^now
      )

    case Repo.one(query) do
      %Request{status: "pending"} -> {:pending}
      %Request{status: "approved"} = row -> consume_and_mint(row)
      _ -> {:error, :expired_or_invalid}
    end
  end

  def poll(_), do: {:error, :expired_or_invalid}

  # The atomic consume: delete THIS approved row; a count of 1 means we won the
  # race and own the mint. Zero means a concurrent poll already consumed it (or
  # it flipped out from under us) — fail closed.
  defp consume_and_mint(%Request{} = row) do
    {count, _} =
      from(r in Request, where: r.id == ^row.id and r.status == "approved")
      |> Repo.delete_all()

    with 1 <- count,
         %{} = user <- Accounts.get_user(row.user_id),
         {:ok, team} <- mint_team(row, user),
         # ORIGIN "device_link": the only mint site outside the router, and the
         # one the SPA most needs — a session that appeared without anyone
         # typing a password into this browser. The row's own captured IP + UA
         # ride along as before; `client_name` is NOT folded in here, because
         # the origin answers HOW the session was established, not WHO asked.
         {:ok, token} <-
           Accounts.create_user_session_token(user,
             ip_address: row.ip_address,
             user_agent: row.user_agent,
             origin: "device_link"
           ) do
      {:ok, token, team}
    else
      _ -> {:error, :expired_or_invalid}
    end
  end

  # The team the minted session answers with. Unbound → the approver's primary
  # team (the original, /login-identical behaviour). Team-bound → that team, but
  # ONLY if the approver is still a member at mint time: a membership revoked
  # between approve and poll fails closed rather than minting into a team the
  # user has left.
  defp mint_team(%Request{requested_team_id: nil}, user), do: {:ok, Accounts.primary_team(user)}

  defp mint_team(%Request{requested_team_id: team_id}, user) do
    member? =
      Repo.exists?(
        from(m in TeamMembership, where: m.team_id == ^team_id and m.user_id == ^user.id)
      )

    case member? && Accounts.get_team(team_id) do
      %{} = team -> {:ok, team}
      _ -> {:error, :team_mismatch}
    end
  end

  @doc """
  Delete every expired request. Hygiene only (expiry is enforced in-band by every
  query above). Returns `%{reaped: count}`; the `DeviceAuthReaper` Oban worker
  calls this per minute.
  """
  @spec reap_expired() :: %{reaped: non_neg_integer()}
  def reap_expired do
    now = DateTime.utc_now()

    {count, _} =
      from(r in Request, where: r.expires_at <= ^now)
      |> Repo.delete_all()

    %{reaped: count}
  end

  ## Internals ---------------------------------------------------------------

  # Hash of the CANONICAL user_code — upper-cased, with the display dash and any
  # stray whitespace stripped — so a browser that submits "XXXX-XXXX", "xxxxxxxx",
  # or "XXXX XXXX" all resolve to the same stored hash.
  defp user_code_hash(user_code) when is_binary(user_code),
    do: UserToken.hash_token(normalize_user_code(user_code))

  defp normalize_user_code(user_code) do
    user_code
    |> String.upcase()
    |> String.replace(~r/[^0-9A-Z]/, "")
  end

  # Draw @user_code_length CSPRNG chars from the alphabet and format as XXXX-XXXX.
  defp generate_user_code do
    raw = @user_code_length |> random_chars() |> List.to_string()
    <<a::binary-size(4), b::binary-size(4)>> = raw
    a <> "-" <> b
  end

  # Rejection-sample CSPRNG bytes so every alphabet index is EQUIPROBABLE (no
  # modulo bias): reject any byte in the short tail that doesn't divide evenly by
  # the alphabet size. With a 30-char alphabet the reject rate is 16/256 (~6%).
  defp random_chars(count) do
    n = length(@user_code_alphabet)
    ceiling = 256 - rem(256, n)
    take_chars(n, ceiling, count, [])
  end

  defp take_chars(_n, _ceiling, 0, acc), do: Enum.reverse(acc)

  defp take_chars(n, ceiling, remaining, acc) do
    byte = :crypto.strong_rand_bytes(1) |> :binary.first()

    if byte < ceiling do
      take_chars(n, ceiling, remaining - 1, [Enum.at(@user_code_alphabet, rem(byte, n)) | acc])
    else
      take_chars(n, ceiling, remaining, acc)
    end
  end

  defp normalize_client_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp normalize_client_name(_), do: nil

  # The FK on requested_team_id tripped: the named team does not exist.
  defp unknown_team?(%Ecto.Changeset{errors: errors}),
    do: Keyword.has_key?(errors, :requested_team)

  defp hash_collision?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, _} -> field in [:device_code_hash, :user_code_hash] end)
  end
end
