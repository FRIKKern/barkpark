defmodule Barkpark.Tenancy.WorkspaceBundle.ImportConfinement do
  @moduledoc """
  A workspace bundle import by a caller the operator allowlist does not NAME
  stays inside the bundle's own workspace (task-1a6cde75b0adae76). A listed
  operator's import never enters this module.

  A bundle is an uploaded tar of raw `COPY` text, so every value in it is the
  uploader's choice. The engine (`WorkspaceBundle`) calls three hooks:
  `begin!/3` before any write, `import!/5` per member, `settle!/2` after the
  members land.

  ## In every mode

    * A NEW workspace lands in no organization. A workspace that already
      exists keeps its current `organization_id` and the other operator
      columns (`@operator_columns`). Joining an organization goes only through
      the guarded attach route.
    * Every row stays in the bundle's workspace (`ImportConfinement.Rows`),
      and a `webhooks` row carries no audit subscription.
    * User-bound rows (a user-owned token, its sessions, a user seat) travel
      only for a user already seated in the existing target, read from the
      database before the import, and only when the importer administers it. The rest are withheld, and the receipt, the
      log line and the audit row list them: rows per table and the user ids.

  ## Observe first (`mode/0`)

    * The importer must already administer an existing target, or the
      same-slug shell a merge would replace.
    * Seats, tokens and secrets (`@observe_tables`) are withheld.

  `:observe` (the default) lets the import through as before and records what
  `:enforce` would do: one log line and one audit row
  (`workspace_import.confinement`), after the import commits.
  `:enforce` refuses (422 `invalid_bundle`) or withholds.
  `BARKPARK_IMPORT_CONFINEMENT=enforce|observe` wins over
  `config :barkpark, :import_confinement`.
  """

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Tenancy.WorkspaceBundle.ImportConfinement.Rows

  @observe_tables ~w(access_grants api_tokens secrets secrets_audit token_sessions workspace_invitations workspace_memberships)

  # Columns an operator (or the instance) sets, never the tenant.
  @operator_columns ~w(organization_id quota suspended suspended_reason suspended_at expires_at tier archived_at)

  @action "workspace_import.confinement"

  @doc "Tables `:enforce` withholds from a confined import."
  def observe_tables, do: @observe_tables

  @doc "Workspace-row columns a confined import never takes from the bundle."
  def operator_columns, do: @operator_columns

  @doc """
  `:observe` (the default) or `:enforce`. `BARKPARK_IMPORT_CONFINEMENT` wins;
  otherwise the config value, where anything but `:enforce` reads as `:observe`.
  """
  @spec mode() :: :observe | :enforce
  def mode do
    case System.get_env("BARKPARK_IMPORT_CONFINEMENT") do
      "enforce" -> :enforce
      "observe" -> :observe
      _ -> if config_mode() == :enforce, do: :enforce, else: :observe
    end
  end

  defp config_mode, do: Application.get_env(:barkpark, :import_confinement, :observe)

  @doc "The engine's `:confine` option: true when the caller is not a listed operator."
  def flag!(opts) do
    case Keyword.get(opts, :confine, false) do
      flag when is_boolean(flag) -> flag
      other -> raise ArgumentError, "invalid :confine #{inspect(other)} (expected a boolean)"
    end
  end

  @doc """
  Hook before any write: `nil` for an unconfined import, else the state the
  other hooks take. Reads the catalog while every member FK still exists.
  """
  def begin!(%{confine: false}, _manifest, _mode), do: nil

  def begin!(%{confine: true, grant: grant}, manifest, mode) do
    enforce? = mode() == :enforce
    ws_id = Rows.ws_id!(manifest)
    prior = read_operator_columns(ws_id)
    target_issue = prior && admin_issue(grant, ws_id, "import into")
    issues = Enum.reject([shell_issue(manifest, ws_id, mode, grant), target_issue], &is_nil/1)

    if enforce? and issues != [], do: refuse_target!(hd(issues))
    Rows.reset_user_rows()

    %{
      manifest: manifest,
      enforce?: enforce?,
      prior: prior,
      issues: issues,
      # Seats count only for an importer who administers the existing target.
      seated: if(prior && is_nil(target_issue), do: seated_users(ws_id), else: []),
      catalog: Rows.catalog()
    }
  end

  @doc "Hook per member. Unconfined, it calls the engine's own `import_member/3`."
  def import!(state, %{"name" => table} = entry, dumps, mode, import_member) do
    dump = Map.get(dumps, table, "")

    cond do
      is_nil(state) ->
        import_member.(entry, dump, mode)

      state.enforce? and table in @observe_tables ->
        release!(dump)

      entry["row_count"] == 0 ->
        release!(dump)

      true ->
        n = Rows.import_member!(entry, dump, mode, state)
        release!(dump)
        n
    end
  end

  # As the engine's `release_member/1`: the member file is the engine's own
  # extraction path, deleted once read. Returns 0 rows for the skipped case.
  # sobelow_skip ["Traversal.FileModule"]
  defp release!(dump) do
    with {:file, path} <- dump, do: File.rm(path)
    0
  end

  @doc """
  Hook after the members land: put the operator columns back, and name the rows
  the bundle carried that were not written (`:withheld`, and per user-bound
  table `:withheld_user_rows`, only when there are any) and what `:enforce`
  would have done (`:confinement_observed`).
  """
  def settle!(stats, nil), do: stats

  def settle!(stats, state) do
    settle_workspace_row!(state.manifest, state.prior)
    landed = stats.tables

    withheld =
      for %{"name" => t, "row_count" => n} <- state.manifest["tables"] || [],
          is_integer(n) and n > Map.get(landed, t, 0),
          into: %{},
          do: {t, n - Map.get(landed, t, 0)}

    would_withhold =
      for t <- @observe_tables,
          not state.enforce? and Map.get(landed, t, 0) > 0,
          into: %{},
          do: {t, Map.get(landed, t)}

    observed = %{would_withhold: would_withhold, would_refuse: state.issues}

    user_rows = Rows.take_user_rows()

    stats
    |> put_unless_empty(:withheld, withheld, withheld == %{})
    |> put_unless_empty(:withheld_user_rows, user_rows, user_rows == %{})
    |> put_unless_empty(
      :confinement_observed,
      observed,
      would_withhold == %{} and state.issues == []
    )
  end

  defp put_unless_empty(map, _key, _value, true), do: map
  defp put_unless_empty(map, key, value, false), do: Map.put(map, key, value)

  @doc """
  After the import committed: one log line and one audit row naming the
  withheld user-bound rows and what `:enforce` would have done. A no-op when
  there is nothing to report. Never raises.
  """
  def record(%{manifest: manifest} = stats, principal)
      when is_map_key(stats, :confinement_observed) or is_map_key(stats, :withheld_user_rows) do
    actor = principal && Map.get(principal, :id)
    ws_id = manifest["workspace_id"]
    seen = Map.get(stats, :confinement_observed, %{would_withhold: %{}, would_refuse: []})
    user_rows = Map.get(stats, :withheld_user_rows, %{})

    Logger.warning(
      "workspace_import_confinement actor=#{actor || "none"} workspace_id=#{ws_id} " <>
        "withheld_user_rows=#{inspect(user_rows)} " <>
        "would_withhold=#{inspect(seen.would_withhold)} would_refuse=#{inspect(seen.would_refuse)}"
    )

    Barkpark.Audit.emit(%{
      category: "access",
      action: @action,
      subject: ws_id,
      actor_type: "api_token",
      actor_id: actor,
      workspace_id: ws_id,
      metadata: %{
        "withheld_user_rows" => user_rows,
        "would_withhold" => seen.would_withhold,
        "would_refuse" => Enum.map(seen.would_refuse, &Map.new(&1, fn {k, v} -> {"#{k}", v} end))
      }
    })

    :ok
  rescue
    error -> Logger.error("import confinement record failed: #{Exception.message(error)}")
  end

  def record(_stats, _principal), do: :ok

  # ── Workspace row ───────────────────────────────────────────────────────────

  # A new workspace (`prior` nil) lands in no organization; an existing one
  # keeps what it had. `sets` comes from the fixed @operator_columns list;
  # values are bind params.
  # sobelow_skip ["SQL.Query"]
  defp settle_workspace_row!(manifest, prior) do
    {cols, values} =
      if prior,
        do: {@operator_columns, Enum.map(@operator_columns, &prior[&1])},
        else: {["organization_id"], [nil]}

    sets =
      cols
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {col, i} -> "#{Rows.qi(col)} = $#{i}" end)

    Repo.query!(
      "UPDATE workspaces SET #{sets} WHERE id = $1::uuid",
      [Ecto.UUID.dump!(Rows.ws_id!(manifest)) | values]
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp read_operator_columns(ws_id) do
    cols = Enum.map_join(@operator_columns, ", ", &Rows.qi/1)

    case Repo.query!("SELECT #{cols} FROM workspaces WHERE id = $1::uuid", [
           Ecto.UUID.dump!(ws_id)
         ]) do
      %{rows: [row]} -> Map.new(Enum.zip(@operator_columns, row))
      %{rows: []} -> nil
    end
  end

  defp seated_users(ws_id) do
    Repo.query!(
      "SELECT principal_id::text FROM workspace_memberships " <>
        "WHERE workspace_id = $1::uuid AND principal_type = 'user'",
      [Ecto.UUID.dump!(ws_id)]
    ).rows
    |> List.flatten()
  end

  # ── Target admin ────────────────────────────────────────────────────────────

  # Merge only: a same-slug workspace under another id is the shell the
  # engine's PDS-D9 adopt branch would delete and replace.
  defp shell_issue(_manifest, _ws_id, :clean, _grant), do: nil

  defp shell_issue(manifest, ws_id, :merge, grant) do
    case Repo.query!(
           "SELECT id::text FROM workspaces WHERE slug = $1 AND id <> $2::uuid",
           [manifest["workspace_slug"], Ecto.UUID.dump!(ws_id)]
         ).rows do
      [[shell_id]] -> admin_issue(grant, shell_id, "replace")
      [] -> nil
    end
  end

  defp admin_issue({principal_id, principal_type}, ws_id, verb) do
    kind = if principal_type == "user", do: :user, else: :api_token

    case TenancyAuth.membership(principal_id, ws_id, kind) do
      %Membership{role: role} when role in ["owner", "admin"] -> nil
      _ -> %{workspace_id: ws_id, verb: verb}
    end
  end

  defp admin_issue(nil, ws_id, verb), do: %{workspace_id: ws_id, verb: verb}

  defp refuse_target!(%{workspace_id: ws_id, verb: verb}) do
    raise Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError,
      code: "invalid_bundle",
      message:
        "this bundle would #{verb} existing workspace #{ws_id}, which the caller does not " <>
          "administer. Only its admins, or a listed instance operator, may do that."
  end
end
