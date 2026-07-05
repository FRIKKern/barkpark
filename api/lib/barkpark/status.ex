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
    components = [
      check(:database, &database_ok?/0),
      check(:migrations, &migrations_current?/0),
      check(:plugins, &plugins_ok?/0)
    ]

    incidents = open_incidents()
    overall = components |> Enum.map(& &1.status) |> fold_status() |> apply_incidents(incidents)

    %{
      status: overall,
      components: components,
      open_incidents: length(incidents),
      version: safe(fn -> Barkpark.BuildInfo.version() end, "unknown"),
      uptime_seconds: node_uptime_seconds(),
      checked_at: DateTime.utc_now()
    }
  end

  defp check(name, probe) do
    status = if safe(probe, false), do: :operational, else: :degraded
    %{component: name, status: status}
  end

  defp database_ok? do
    match?({:ok, _}, Repo.query("SELECT 1"))
  end

  defp migrations_current? do
    Ecto.Migrator.migrations(Repo)
    |> Enum.all?(fn {status, _v, _n} -> status == :up end)
  end

  defp plugins_ok? do
    is_list(Barkpark.Plugins.Registry.all())
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
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Incident, uuid)
      :error -> nil
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
