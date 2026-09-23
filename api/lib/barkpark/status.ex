defmodule Barkpark.Status do
  @moduledoc """
  Service health + public incident history behind the status page.

  `health/0` probes real components (database, migrations, plugin registry) and
  folds them — together with any unresolved incidents — into one overall status
  in `{operational, degraded, partial_outage, major_outage}`. Incidents are
  first-class rows so the page shows a real history, and the SLA targets come
  from config so the commitment is a single source of truth.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Content.CodelistHealth
  alias Barkpark.Repo
  alias Barkpark.Status.Incident

  @statuses_worst_last [:operational, :degraded, :partial_outage, :major_outage]

  # ── Health ───────────────────────────────────────────────────────────────────

  @doc """
  Probe every component and return the overall status plus per-component detail.
  Incidents fold in: an unresolved `major`/`critical` incident forces at least
  `partial_outage`, a `minor` one `degraded`.
  """
  @spec health() :: map()
  def health do
    # Each probe runs ONCE per request and feeds both the component verdict
    # and the inventory published beside it, so the two can never disagree.
    migrations = migration_state()
    plugins = safe(fn -> Barkpark.Plugins.Registry.all() end, :probe_failed)

    components = [
      check(:database, &database_ok?/0),
      component(:migrations, if(migrations.pending == 0, do: :operational, else: :degraded), nil),
      component(:plugins, if(is_list(plugins), do: :operational, else: :degraded), nil),
      check(:mail, &mail_deliverable?/0),
      codelists_component(),
      kek_previous_component()
    ]

    incidents = open_incidents()
    overall = components |> Enum.map(& &1.status) |> fold_status() |> apply_incidents(incidents)

    %{
      status: overall,
      components: components,
      open_incidents: length(incidents),
      version: safe(fn -> Barkpark.BuildInfo.version() end, "unknown"),
      commit: commit(),
      migrations: migrations,
      plugins_enabled: if(is_list(plugins), do: length(plugins)),
      uptime_seconds: node_uptime_seconds(),
      checked_at: DateTime.utc_now()
    }
  end

  defp check(name, probe) do
    status = if safe(probe, false), do: :operational, else: :degraded
    %{component: name, status: status, detail: nil}
  end

  @doc """
  The `:codelists` component: does the box actually hold the codelists its
  plugins declare?

  A boot seed that times out is rescued at three levels, so a node with no Thema
  codes at all still answers 200 and still reports every other component green.
  This is the one probe that says otherwise, and its `detail` NAMES the lists —
  `"codelist onixedit:thema is empty or stale: …"` — because "codelists:
  degraded" is not something an operator can act on.

  Skipped (reported `:operational`, no detail) on a node configured not to run
  the boot codelist seeders — `config :barkpark, run_boot_codelist_seeders:
  false`, which is the test env. Such a node never promised to hold codelist
  DATA, so dyeing it degraded would be noise, not signal.

  `opts` are passed through to `CodelistHealth.audit/1` (`:requirements`), so a
  caller can probe an arbitrary roster.
  """
  @spec codelists_component(keyword()) :: %{
          component: :codelists,
          status: :operational | :degraded,
          detail: String.t() | nil
        }
  def codelists_component(opts \\ []) do
    cond do
      not boot_codelist_seeders_enabled?() ->
        component(:codelists, :operational, nil)

      true ->
        case safe(fn -> CodelistHealth.audit(opts) end, :probe_failed) do
          %{status: :ok} ->
            component(:codelists, :operational, nil)

          %{status: :degraded} = audit ->
            component(:codelists, :degraded, CodelistHealth.summary(audit))

          _ ->
            component(:codelists, :degraded, "codelist audit could not be run")
        end
    end
  end

  defp component(name, status, detail),
    do: %{component: name, status: status, detail: detail}

  @doc """
  The `:kek_previous` component: is every BARKPARK_KEK_PREVIOUS rotation key
  actually usable?

  `Barkpark.Crypto.LocalKek.keys/0` DISCARDS a malformed previous key in silence
  (`Enum.filter(&match?(<<_::binary-size(32)>>, &1))`), so a single typo in a
  rotation entry makes every blob sealed under that KEK permanently
  undecryptable — with a clean boot and, until now, nothing an operator could
  read. `config/runtime.exs` audits each entry at boot and records the verdict
  under `Barkpark.Crypto.LocalKek`'s `:kek_previous_audit` key; this probe
  republishes it where a human actually looks. A boot log line alone would be
  theatre.

  `detail` names HOW MANY entries were discarded and their 1-based POSITIONS.
  It NEVER echoes an entry: those are key material.

  The four states are deliberately distinguishable, so that a FAILED READ can
  never be mistaken for a healthy box:

    * audit says `checked: true, discarded: 0` -> `:operational`, no `detail`
      (and `component_json/1` omits the key entirely) — the only silent arm.
    * audit says `discarded: n > 0` -> `:degraded`, `detail` names n + positions.
    * audit says `checked: false` -> `:operational` WITH a `detail` saying the
      audit did not apply: with no primary BARKPARK_KEK, runtime.exs never
      configures `previous_keys`, so no entry is consumed and none is discarded.
    * NO audit recorded (anything else, including `nil`) -> `:degraded`, because
      that means config/runtime.exs did not run or did not record a verdict.
      This box's rotation keys are UNKNOWN, which is not the same as good.
  """
  @spec kek_previous_component() :: %{
          component: :kek_previous,
          status: :operational | :degraded,
          detail: String.t() | nil
        }
  def kek_previous_component do
    # Never let a surprising config shape 500 the public status page: anything
    # that is not a keyword list carrying an audit falls through to the
    # `:degraded` "audit is MISSING" arm, which is the honest verdict.
    case Application.get_env(:barkpark, Barkpark.Crypto.LocalKek, []) do
      config when is_list(config) -> Keyword.get(config, :kek_previous_audit)
      _ -> nil
    end
    |> kek_previous_verdict()
  end

  defp kek_previous_verdict(%{checked: true, discarded: 0}),
    do: component(:kek_previous, :operational, nil)

  defp kek_previous_verdict(%{checked: true, discarded: n, positions: positions})
       when is_integer(n) and n > 0 do
    component(
      :kek_previous,
      :degraded,
      "BARKPARK_KEK_PREVIOUS: #{n} malformed #{plural_entry(n)} discarded at 1-based " <>
        "position#{if n == 1, do: "", else: "s"} #{Enum.join(positions, ", ")} — " <>
        "not base64 of exactly 32 raw bytes. Barkpark.Crypto.LocalKek drops " <>
        "#{if n == 1, do: "it", else: "them"}, so blobs sealed under that KEK cannot be " <>
        "unwrapped and DataKeys.rewrap_all/0 cannot finish the rotation. Fix or remove " <>
        "the named position(s) and restart. The entries themselves are never published here."
    )
  end

  defp kek_previous_verdict(%{checked: false}),
    do:
      component(
        :kek_previous,
        :operational,
        "not applicable: BARKPARK_KEK is unset, so config/runtime.exs configures no " <>
          "previous_keys and no BARKPARK_KEK_PREVIOUS entry is consumed or discarded."
      )

  defp kek_previous_verdict(_missing),
    do:
      component(
        :kek_previous,
        :degraded,
        "BARKPARK_KEK_PREVIOUS audit is MISSING: config/runtime.exs recorded no verdict " <>
          "under Barkpark.Crypto.LocalKek :kek_previous_audit. The rotation keys on this " <>
          "box are UNKNOWN, which is NOT the same as known-good — do not read this as healthy."
      )

  defp plural_entry(1), do: "entry"
  defp plural_entry(_), do: "entries"

  defp boot_codelist_seeders_enabled? do
    Application.get_env(:barkpark, :run_boot_codelist_seeders, true)
  end

  defp database_ok? do
    match?({:ok, _}, Repo.query("SELECT 1"))
  end

  @doc """
  Migration state of this node: the highest APPLIED migration version and how
  many on-disk migrations are still PENDING (`:down`).

  One `Ecto.Migrator.migrations/2` read — the same read the `:migrations`
  component's verdict comes from (`pending == 0` is operational), so the
  published numbers and the colour cannot drift apart.

  A probe that fails reports `%{latest_applied: nil, pending: nil}`: UNKNOWN,
  never a `0` that would read as "nothing pending". `latest_applied` is also
  `nil` on a database with no applied migration at all.

  `directories` defaults to the repo's own migrations path; a caller (a test)
  may point it at another directory to stage a pending migration.
  """
  @spec migration_state([String.t()] | nil) :: %{
          latest_applied: non_neg_integer() | nil,
          pending: non_neg_integer() | nil
        }
  def migration_state(directories \\ nil) do
    case safe(fn -> read_migrations(directories) end, :probe_failed) do
      list when is_list(list) -> summarize_migrations(list)
      _ -> %{latest_applied: nil, pending: nil}
    end
  end

  defp read_migrations(nil), do: Ecto.Migrator.migrations(Repo)
  defp read_migrations(dirs), do: Ecto.Migrator.migrations(Repo, dirs)

  defp summarize_migrations(list) do
    applied = for {:up, version, _name} <- list, do: version

    %{
      latest_applied: if(applied == [], do: nil, else: Enum.max(applied)),
      pending: Enum.count(list, &match?({:down, _, _}, &1))
    }
  end

  # A node whose mailer discards every message is NOT operational: password
  # reset and magic-link sign-in are down, and because those endpoints answer
  # 200 for anti-enumeration reasons, this probe is the only place a human or an
  # uptime monitor can see it. `drops_mail?/0` deliberately does not count the
  # test-capture adapter, so this stays green under MIX_ENV=test rather than
  # dyeing every suite degraded. Reports `:degraded`, never an outage tone — the
  # rest of the API is genuinely serving.
  defp mail_deliverable? do
    not Barkpark.Mailer.drops_mail?()
  end

  # Worst component status wins.
  defp fold_status(statuses) do
    Enum.max_by(statuses, &status_rank/1, fn -> :operational end)
  end

  defp status_rank(s), do: Enum.find_index(@statuses_worst_last, &(&1 == s)) || 0

  defp apply_incidents(base, []), do: base

  defp apply_incidents(base, incidents) do
    from_incidents =
      incidents
      |> Enum.map(fn i ->
        case i.impact do
          "critical" -> :major_outage
          "major" -> :partial_outage
          _ -> :degraded
        end
      end)
      |> fold_status()

    fold_status([base, from_incidents])
  end

  @doc """
  Short git sha of the RUNNING build — the one deploy record produced by the
  running BEAM rather than by a file a script promised to write.

  This is an IDENTITY, unlike `version` ("A.B.C.D", whose D is a commits-since-tag
  DISTANCE — every commit at the same distance shares one string). It is published
  on the public status payload so an unattended owner (or their uptime monitor,
  with no bearer token) can read what the box is actually running.

  Never nil, never absent: a build with no derivable sha renders `"unknown"`, so
  the field's presence never doubles as an "all good" signal. The resolver is
  injectable so that fallback is testable.
  """
  @spec commit((-> String.t())) :: String.t()
  def commit(resolver \\ &Barkpark.BuildInfo.commit/0) do
    case safe(resolver, "unknown") do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> "unknown"
    end
  end

  @doc "Overall status atom only (`operational` when all clear)."
  @spec overall_status() :: atom()
  def overall_status, do: health().status

  # ── Incidents ─────────────────────────────────────────────────────────────────

  @doc "Recent incidents, newest first (default 20)."
  @spec recent_incidents(non_neg_integer()) :: [Incident.t()]
  def recent_incidents(limit \\ 20) do
    Repo.all(from i in Incident, order_by: [desc: i.started_at], limit: ^limit)
  end

  @doc "Currently-unresolved incidents."
  @spec open_incidents() :: [Incident.t()]
  def open_incidents do
    Repo.all(from i in Incident, where: is_nil(i.resolved_at), order_by: [desc: i.started_at])
  end

  @doc "Open a new incident. `started_at` defaults to now."
  @spec create_incident(map()) :: {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def create_incident(attrs) do
    attrs = Map.put_new(stringify(attrs), "started_at", DateTime.utc_now())

    %Incident{}
    |> Incident.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an incident (post an update, change status/body)."
  @spec update_incident(Incident.t(), map()) :: {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def update_incident(%Incident{} = incident, attrs) do
    incident |> Incident.changeset(stringify(attrs)) |> Repo.update()
  end

  @doc "Resolve an incident: mark it resolved + stamp `resolved_at`."
  @spec resolve_incident(Incident.t()) :: {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def resolve_incident(%Incident{} = incident) do
    update_incident(incident, %{status: "resolved", resolved_at: DateTime.utc_now()})
  end

  @doc "Fetch one incident by id, or nil."
  @spec get_incident(binary()) :: Incident.t() | nil
  def get_incident(id) do
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Incident, uuid)
    end
  end

  # ── SLA ────────────────────────────────────────────────────────────────────────

  @doc """
  The published SLA: uptime target + service-credit schedule. Config-driven so
  the page, the JSON API, and the SLA doc share one source of truth.
  """
  @spec sla() :: map()
  def sla do
    Application.get_env(:barkpark, :sla,
      uptime_target: "99.9%",
      measurement_window: "monthly",
      credits: [
        %{below: "99.9%", credit: "10%"},
        %{below: "99.0%", credit: "25%"},
        %{below: "95.0%", credit: "50%"}
      ]
    )
    |> Map.new()
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  @doc "Seconds since this node booted."
  @spec node_uptime_seconds() :: non_neg_integer()
  def node_uptime_seconds do
    {ms, _} = :erlang.statistics(:wall_clock)
    div(ms, 1000)
  end

  # Run a probe that may raise/return anything; coerce failures to `default`.
  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
