defmodule BarkparkCloud.PlatformDelivery do
  @moduledoc """
  deploy-reliability W23 (charter D385) — one durable row per PLATFORM delivery:
  a sha, the run that delivered it, and the clocks around it.

  ## Why the name is `platform_deliveries` and not `deliveries`

  The short name is taken twice, and both holders are live:

    * `notification_deliveries` / `BarkparkCloud.Notifications.Delivery` — the
      durable notification send log (`GET /v1/notifications/deliveries`).
    * `deliveries` is already a `bp cloud webhook` CLI verb, proxied through
      `GET /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries`.

  A bare `Delivery` module could not be added without shadowing the first, and a
  bare `deliveries` route could not be added without colliding, in an operator's
  head, with the second. The long name is the honest one: these are the
  PLATFORM's own deploys, not a tenant's webhooks and not an email.

  ## Why it is its own table

  `deployments.site_id` is NOT NULL with an FK to `sites`. Barkpark's own
  platform deploys have no site row, so they cannot be represented there at all.
  See the migration for the full argument.

  ## The identity: (sha, delivering_run_id, target)

  179 of 180 non-success deploy runs carry ZERO jobs, so ~36% of merged shas are
  CARRIED by a later sha's run rather than delivered by one of their own. A
  `(sha, first_seen_at)` key would fold two runs delivering the same carried sha
  into one row — losing exactly the deliveries this wave exists to make visible.
  The run id is part of the identity for that reason.

  `target` is part of it too (W24, charter D422, which amends D410 on this key).
  `deploy.yml`'s `control-plane` and `instance` jobs are two jobs of ONE workflow
  run and share GITHUB_RUN_ID, so W23's `(sha, delivering_run_id, first_seen_at)`
  key destroyed the second leg of every deploy and answered 200 — measured live:
  a batch of two rows differing only in `target` returned
  `%{received: 2, recorded: 1}`. No choice of clock repairs that (a run-stable
  stamp loses the leg; a per-post stamp duplicates on retry), so the key names
  `target` and names no clock at all. `first_seen_at` stays as the ordering
  clock — PAYLOAD, not identity.

  ## Never raises into an HTTP response

  `record_all/1` and `list/1` return tagged tuples for every outcome, including
  `{:error, :unavailable}` when the table is not there yet. That case is REAL,
  not defensive: `deploy.yml`'s instance job fires on
  `^(api|internal|deploy|connectors|templates)/` and does NOT require the
  `cloud/**` merge that carries this migration, so an api-only merge posts to a
  control plane whose table does not exist. That must be a LOUD, typed 503 —
  never a 500, and never a silent `|| true`, which is the exact blindness this
  wave exists to end.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias BarkparkCloud.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Append-only stream: stamp inserted_at, never updated_at.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @targets ~w(cp instance)
  @default_target "cp"

  # The write columns, in the order the wire carries them. `insert_all/3` takes a
  # bare map, so this list is what turns a validated changeset back into a row.
  @columns [
    :sha,
    :delivering_run_id,
    :first_seen_at,
    :merged_at,
    :queued_seconds,
    :build_seconds,
    :serving_since,
    :target,
    :carried,
    :queued_self_seconds,
    :queued_pickup_seconds,
    :queued_stall_seconds
  ]

  # The bare list's pinned window. Never "everything": an unbounded list is a
  # page that gets slower every day and a response whose size nobody predicted.
  @default_limit 50
  @max_limit 200

  # The unique index this upsert conflicts on, by name — so a rename of the
  # index is a compile-adjacent break here rather than a silent double-write.
  # The name is a LITERAL ATOM on both sides, which Postgres only resolves at
  # RUNTIME: grep the whole tree when it changes.
  @conflict_target [:sha, :delivering_run_id, :target]
  @conflict_index :platform_deliveries_sha_run_target_index

  schema "platform_deliveries" do
    field :sha, :string
    field :delivering_run_id, :string
    field :first_seen_at, :utc_datetime_usec
    field :merged_at, :utc_datetime_usec
    field :queued_seconds, :integer

    # The queue, split into the three intervals an operator can act on. All
    # nullable, carrying this table's law: if the producing query fails they read
    # UNKNOWN, never 0 — a 0 would read as "the queue was instant".
    field :queued_self_seconds, :integer
    field :queued_pickup_seconds, :integer
    field :queued_stall_seconds, :integer

    field :build_seconds, :integer
    field :serving_since, :utc_datetime_usec
    field :target, :string, default: @default_target

    # NO DEFAULT (D422). An omitted `carried` must read `nil` — "nobody measured
    # this" — never a measured `false`. A box-side writer does not know whether a
    # sha rode another sha's run, and recording that ignorance as `false` is
    # exactly the carried-vs-caused lie this epic exists to end.
    field :carried, :boolean

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The `target` vocabulary: which leg delivered this sha."
  @spec targets() :: [binary()]
  def targets, do: @targets

  @doc "The default `target` when the writer does not name one."
  @spec default_target() :: binary()
  def default_target, do: @default_target

  @doc "The bare list's pinned window size, and its ceiling."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(normalize(attrs), @columns)
    |> validate_required([:sha, :delivering_run_id, :first_seen_at])
    |> validate_format(:sha, ~r/^[0-9a-f]{7,64}$/,
      message: "must be a lowercase hex commit sha (7-64 chars)"
    )
    |> validate_length(:delivering_run_id, min: 1, max: 64)
    |> validate_inclusion(:target, @targets)
    |> validate_number(:queued_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:build_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:queued_self_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:queued_pickup_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:queued_stall_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint(@conflict_target, name: @conflict_index)
  end

  # The wire is JSON written by a shell script, so both key styles and a numeric
  # run id are expected shapes, not sloppiness. A GitHub run id arrives as a JSON
  # NUMBER; `cast/3` would reject it for a :string field, which would make the
  # recorder refuse every real payload.
  defp normalize(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
    |> Map.update("delivering_run_id", nil, &stringify/1)
    |> Map.update("sha", nil, &downcase/1)
  end

  defp normalize(_other), do: %{}

  defp stringify(v) when is_integer(v), do: Integer.to_string(v)
  defp stringify(v), do: v

  defp downcase(v) when is_binary(v), do: String.downcase(String.trim(v))
  defp downcase(v), do: v

  @doc """
  Record a BATCH of delivery rows — one call per delivering run, one row per sha
  that run carried.

  IDEMPOTENT on `(sha, delivering_run_id, target)`: the insert is
  `on_conflict: :nothing`, so a retried deploy job re-posts its whole batch and
  writes nothing. `recorded` therefore counts NEW rows and `received` counts what
  the caller sent — a re-post is an honest `%{received: 3, recorded: 0}` rather
  than a fake success.

  Returns:

    * `{:ok, %{received: n, recorded: m}}`
    * `{:error, {:null_column, column}}` — a required column arrived explicitly
      NULL and Postgres refused the row. The caller's payload is wrong, not the
      crown, so this is a typed 422 on the wire and never a 500.
    * `{:error, {:invalid_row, index, errors}}` — one row failed validation; the
      whole batch is refused, because a partially-recorded delivery is a lie
      that is worse than a refusal the caller can retry.
    * `{:error, :unavailable}` — the table is not on this control plane yet.
    * `{:error, term}` — anything else, unwrapped for the log.
  """
  # The naming collision IS the decoy this marker exists for: `deliveries` grep-hits
  # the notification send log and the webhook delivery proxy first, and neither is
  # the platform's own deploy record.
  # @canonical capability:platform-delivery-record aka:deliveries,platform deploy record,per-sha delivery,deploy memory
  @spec record_all(list()) ::
          {:ok, %{received: non_neg_integer(), recorded: non_neg_integer()}}
          | {:error, term()}
  def record_all(rows) when is_list(rows) do
    case normalize_all(rows) do
      {:ok, entries} ->
        now = DateTime.utc_now()

        entries =
          Enum.map(entries, fn entry ->
            entry
            |> Map.put(:id, Ecto.UUID.generate())
            |> Map.put(:inserted_at, now)
          end)

        {recorded, _} =
          Repo.insert_all(__MODULE__, entries,
            on_conflict: :nothing,
            conflict_target: @conflict_target
          )

        {:ok, %{received: length(rows), recorded: recorded}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, classify(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  def record_all(_other), do: {:error, :not_a_list}

  # Validate EVERY row before writing ANY row. `insert_all/3` bypasses
  # changesets, so this is the only place the shape is checked — and it halts on
  # the first bad row so the caller learns WHICH one.
  defp normalize_all(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case changeset(%__MODULE__{}, row) do
        %Ecto.Changeset{valid?: true} = cs ->
          {:cont, {:ok, [entry(cs) | acc]}}

        %Ecto.Changeset{} = cs ->
          {:halt, {:error, {:invalid_row, index, changeset_errors(cs)}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp entry(%Ecto.Changeset{} = cs) do
    cs
    |> apply_changes()
    |> Map.from_struct()
    |> Map.take(@columns)
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%\{(\w+)\}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Read the record back.

  Options (all optional):

    * `:sha` — narrow to one commit. An unknown sha is an honest EMPTY list, not
      a 404: the route exists and the answer "nothing was ever recorded for this
      sha" is the single most useful thing this table can say about a silent
      deploy.
    * `:limit` — clamped to `max_limit/0`, defaulting to `default_limit/0`.

  Ordered newest sighting first. Returns `{:ok, rows}`, `{:error, :unavailable}`
  when the table is absent, or `{:error, term}`.
  """
  @spec list(keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(opts \\ []) do
    limit = clamp_limit(opts[:limit])

    query =
      from(d in __MODULE__,
        order_by: [desc: d.first_seen_at, desc: d.inserted_at],
        limit: ^limit
      )

    query =
      case normalize_sha(opts[:sha]) do
        nil -> query
        sha -> from(d in query, where: d.sha == ^sha)
      end

    {:ok, Repo.all(query)}
  rescue
    error -> {:error, classify(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  A blank/absent sha is `nil` (no filter); anything else is trimmed + downcased.
  Exposed so the route renders back the SAME sha it queried on.
  """
  @spec normalize_sha(term()) :: binary() | nil
  def normalize_sha(sha) when is_binary(sha) do
    case sha |> String.trim() |> String.downcase() do
      "" -> nil
      s -> s
    end
  end

  def normalize_sha(_other), do: nil

  @doc "Clamp a caller-supplied limit into `1..max_limit/0`; nil/junk → the default."
  @spec clamp_limit(term()) :: pos_integer()
  def clamp_limit(nil), do: @default_limit

  def clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  def clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  def clamp_limit(_other), do: @default_limit

  @doc """
  The wire shape of one row. Datetimes render as ISO8601 (`nil` stays `nil` — an
  unknown clock must read as unknown, never as an epoch), and every key the
  writer may send comes back so a reader never has to guess what was recorded.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = d) do
    %{
      sha: d.sha,
      delivering_run_id: d.delivering_run_id,
      first_seen_at: iso(d.first_seen_at),
      merged_at: iso(d.merged_at),
      queued_seconds: d.queued_seconds,
      queued_self_seconds: d.queued_self_seconds,
      queued_pickup_seconds: d.queued_pickup_seconds,
      queued_stall_seconds: d.queued_stall_seconds,
      build_seconds: d.build_seconds,
      serving_since: iso(d.serving_since),
      target: d.target,
      carried: d.carried,
      recorded_at: iso(d.inserted_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # A control plane that has not run this wave's migration yet answers
  # `undefined_table`. That is the ONE database error with a caller-actionable
  # meaning ("your cloud/ merge has not landed"), so it gets its own tag and its
  # own typed HTTP refusal. Everything else stays opaque and is logged.
  defp classify(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: :unavailable

  # A NOT NULL violation is the CALLER's row, not the crown being broken.
  # `validate_required/2` does not catch an explicit `null` on a column it does
  # not list, so the value reaches `insert_all/3` and Postgres refuses it — and
  # until W24 that fell through to the router's 500 `record_failed`, telling a
  # deploy job the platform had failed when its own payload was malformed. Typed
  # 422, and it names the column so the writer fixes the field instead of
  # retrying the same bytes forever.
  defp classify(%Postgrex.Error{postgres: %{code: :not_null_violation} = pg}),
    do: {:null_column, to_string(Map.get(pg, :column) || "unknown")}

  defp classify(error), do: error
end
