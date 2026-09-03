defmodule Barkpark.Tenancy do
  @moduledoc """
  Context for the Workspace -> Project -> (Dataset) tenancy hierarchy.

  Wave 1 foundation: workspace/project lookup + creation and the Default
  Workspace / Default Project the migration backfills. Query scoping,
  token-binding, and auth enforcement are sibling tasks and live elsewhere.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Accounts.User
  alias Barkpark.Audit.ExportSink
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy.{Workspace, Project, Dataset, Membership, Organization}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.Catalog

  @default_slug "default"
  @default_org_slug "default"

  # ── Organizations (thin tier above Workspace, era-w1-org) ────────────────

  @doc "List all organizations."
  @spec list_organizations() :: [Organization.t()]
  def list_organizations, do: Repo.all(from o in Organization, order_by: [asc: o.name])

  @doc "Fetch an Organization by slug, or nil."
  @spec get_organization_by_slug(String.t()) :: Organization.t() | nil
  def get_organization_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Organization, slug: slug)

  @doc "The seeded default Organization (the migration backfills it), or nil."
  @spec get_default_organization() :: Organization.t() | nil
  def get_default_organization, do: get_organization_by_slug(@default_org_slug)

  @doc "Create an Organization from `%{slug, name}`."
  @spec create_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  @doc "The Workspaces that belong to `organization_id`."
  @spec workspaces_for_organization(binary()) :: [Workspace.t()]
  def workspaces_for_organization(organization_id) when is_binary(organization_id) do
    Repo.all(
      from w in Workspace,
        where: w.organization_id == ^organization_id,
        order_by: [asc: w.name]
    )
  end

  @doc "Attach a Workspace to an Organization (or detach with `nil`)."
  @spec assign_workspace_to_organization(Workspace.t(), binary() | nil) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def assign_workspace_to_organization(%Workspace{} = workspace, organization_id) do
    workspace
    |> Workspace.changeset(%{
      slug: workspace.slug,
      name: workspace.name,
      organization_id: organization_id
    })
    |> Repo.update()
  end

  @doc """
  Set (or clear) an organization's org-wide MFA requirement
  (era-w2-org-require-mfa). Opt-in: with the flag false everywhere the auth
  surface is byte-identical to before the feature existed.

  The change lands on the tamper-evident audit trail (`auth` category,
  `require_mfa_changed`) — era-w8 added this; the setter was previously silent.
  `opts` may carry `:actor_id` / `:actor_type` (defaults `"admin"`).
  """
  @spec set_organization_require_mfa(binary(), boolean(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_organization_require_mfa(organization_id, require?, opts \\ [])
      when is_binary(organization_id) and is_boolean(require?) do
    with {:ok, _} <- Ecto.UUID.cast(organization_id),
         %Organization{} = org <- Repo.get(Organization, organization_id) do
      result =
        org
        |> Ecto.Changeset.change(require_mfa: require?)
        |> Repo.update()

      with {:ok, _updated} <- result do
        audit_org_auth_change(org, "require_mfa_changed", %{"require_mfa" => require?}, opts)
      end

      result
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Set (or clear) an organization's org-wide SESSION POLICY
  (era-w8-org-session-policy). Mirrors `set_organization_require_mfa/3`:
  UUID-guarded, `:not_found` on an unknown/malformed id, and the change is
  audited on the tamper-evident trail (`auth` / `session_policy_changed`).

  `policy` is a map carrying either/both of `:idle_timeout_seconds` and
  `:absolute_lifetime_seconds` (atom OR string keys). A value must be a
  positive integer (a bound, in seconds) or `nil` (clear the bound → no
  limit). An absent key leaves that axis untouched; a non-positive / non-integer
  value returns `{:error, :invalid_policy}` without touching the DB. With both
  axes NULL the session-auth surface is byte-identical to the hardcoded default.

  `opts` may carry `:actor_id` / `:actor_type` (defaults `"admin"`).
  """
  @spec set_organization_session_policy(binary(), map(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | :not_found | :invalid_policy}
  def set_organization_session_policy(organization_id, policy, opts \\ [])
      when is_binary(organization_id) and is_map(policy) do
    with {:ok, _} <- Ecto.UUID.cast(organization_id),
         {:ok, changes} <- session_policy_changes(policy),
         %Organization{} = org <- Repo.get(Organization, organization_id) do
      result =
        org
        |> Ecto.Changeset.change(changes)
        |> Repo.update()

      with {:ok, _updated} <- result do
        metadata = Map.new(changes, fn {k, v} -> {Atom.to_string(k), v} end)
        audit_org_auth_change(org, "session_policy_changed", metadata, opts)
      end

      result
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, :invalid_policy} = err -> err
    end
  end

  # Fold a caller-supplied policy map into a validated column-change map. Only
  # present keys land; each value is nil (clear) or a positive integer. Any other
  # value short-circuits to {:error, :invalid_policy} (the DB is never touched).
  defp session_policy_changes(policy) do
    axes = [
      {:session_idle_timeout_seconds, [:idle_timeout_seconds, "idle_timeout_seconds"]},
      {:session_absolute_lifetime_seconds,
       [:absolute_lifetime_seconds, "absolute_lifetime_seconds"]}
    ]

    Enum.reduce_while(axes, {:ok, %{}}, fn {col, aliases}, {:ok, acc} ->
      case fetch_policy_value(policy, aliases) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, col, value)}}
        :invalid -> {:halt, {:error, :invalid_policy}}
      end
    end)
  end

  defp fetch_policy_value(policy, aliases) do
    case Enum.find(aliases, &Map.has_key?(policy, &1)) do
      nil ->
        :absent

      key ->
        case Map.get(policy, key) do
          nil -> {:ok, nil}
          value when is_integer(value) and value > 0 -> {:ok, value}
          _ -> :invalid
        end
    end
  end

  # era-w8: org auth-policy changes land on the tamper-evident audit trail
  # (`auth` category). Best-effort AFTER the write commits — an audit hiccup must
  # never fail a policy write that already succeeded; `Audit.emit/1` runs in its
  # own savepointed transaction so it rolls back only itself.
  defp audit_org_auth_change(%Organization{} = org, action, metadata, opts) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: action,
      subject: org.id,
      actor_type: Keyword.get(opts, :actor_type, "admin"),
      actor_id: Keyword.get(opts, :actor_id),
      metadata: Map.merge(%{"organization_id" => org.id, "org_slug" => org.slug}, metadata)
    })

    :ok
  end

  @doc """
  Resolve the STRICTEST session policy GOVERNING this user across every
  organization reachable through their `principal_type: "user"` workspace
  memberships (era-w8-org-session-policy).

  Mirrors `org_requires_mfa_for_user?/1`'s governing model: any governing org
  can tighten the bound, and a laxer org grants no escape. Strictest-wins per
  axis independently — the SMALLEST positive bound across the governing orgs
  (a `nil`/absent bound imposes no limit and is ignored). Returns
  `%{idle_timeout_seconds: pos_integer | nil, absolute_lifetime_seconds:
  pos_integer | nil}`; both `nil` (the default: no governing org sets a bound)
  means no limit — the byte-identical zero-tax path.
  """
  @spec org_session_policy_for_user(binary()) :: %{
          idle_timeout_seconds: pos_integer() | nil,
          absolute_lifetime_seconds: pos_integer() | nil
        }
  def org_session_policy_for_user(user_id) when is_binary(user_id) do
    rows =
      Repo.all(
        from m in Membership,
          join: w in Workspace,
          on: w.id == m.workspace_id,
          join: o in Organization,
          on: o.id == w.organization_id,
          where: m.principal_type == "user" and m.principal_id == ^user_id,
          select: {o.session_idle_timeout_seconds, o.session_absolute_lifetime_seconds}
      )

    %{
      idle_timeout_seconds: strictest_bound(Enum.map(rows, &elem(&1, 0))),
      absolute_lifetime_seconds: strictest_bound(Enum.map(rows, &elem(&1, 1)))
    }
  end

  def org_session_policy_for_user(_),
    do: %{idle_timeout_seconds: nil, absolute_lifetime_seconds: nil}

  # Strictest bound = smallest POSITIVE value; nil/non-positive bounds impose no
  # limit and drop out. All-nil (or empty) → nil = no limit.
  defp strictest_bound(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> case do
      [] -> nil
      positives -> Enum.min(positives)
    end
  end

  @doc """
  Does any organization GOVERNING this user require MFA enrolment?

  The governing rule (owner-ratified 2026-07-05): **ANY-org-requires →
  enforce, strictest-wins.** A user is governed by every organization
  reachable through their workspace memberships (`principal_type: "user"`);
  if at least one of those orgs sets `require_mfa`, the user must have a
  factor enrolled before the session-auth surface serves them. A user cannot
  escape the requirement by also belonging to a laxer org, and no per-request
  org threading is needed. Workspaces without an organization never govern.
  """
  @spec org_requires_mfa_for_user?(binary()) :: boolean()
  def org_requires_mfa_for_user?(user_id) when is_binary(user_id) do
    Repo.exists?(
      from m in Membership,
        join: w in Workspace,
        on: w.id == m.workspace_id,
        join: o in Organization,
        on: o.id == w.organization_id,
        where:
          m.principal_type == "user" and m.principal_id == ^user_id and
            o.require_mfa == true
    )
  end

  @default_project_slug "default"
  @default_project_name "Default Project"
  @production_dataset_slug "production"

  @doc "Returns the seeded Default Workspace, or nil if the backfill hasn't run."
  @spec get_default_workspace() :: Workspace.t() | nil
  def get_default_workspace do
    Repo.get_by(Workspace, slug: @default_slug)
  end

  @doc "Returns the Default Project under the Default Workspace, or nil."
  @spec get_default_project() :: Project.t() | nil
  def get_default_project do
    case get_default_workspace() do
      nil -> nil
      %Workspace{id: ws_id} -> Repo.get_by(Project, workspace_id: ws_id, slug: @default_slug)
    end
  end

  @doc """
  The project a scope should resolve a dataset slug within, or `nil`.

  An EXPLICIT `:project_id` always wins. The seeded Default Project is the right
  answer ONLY when no workspace resolved — the legacy flat/Default path, whose
  behaviour is unchanged.

  A resolved workspace with NO project returns `nil`, and that is the whole
  point. A token carries no project binding (`Auth.create_token/5` has no
  project argument), `Plugs.DeriveWorkspaceFromToken` assigns only
  `:current_workspace`, and `Plugs.AssignDefaultScope` DELIBERATELY declines to
  stamp the Default Project for a non-Default workspace — its moduledoc: pairing
  workspace A with a Default-owned project means "every scoped read matches zero
  rows, and every scoped write stamps a `project_id` belonging to another
  tenant". `ScopeHelpers.put_scope/3` drops a nil scope entirely
  (`put_scope(opts, _key, nil), do: opts`), so `:project_id` arrives ABSENT
  rather than nil — which is why a `Keyword.get(opts, :project_id) ||
  default_project_id()` fallback silently re-created exactly that cross-tenant
  pairing. Callers treat `nil` as "no dataset_id" and keep their
  workspace-scoped `dataset` STRING filter.

  `:workspace_id` may be the `:shared_only` sentinel `ScopeHelpers` assigns when
  an HTTP request resolved no workspace; that is an unresolved workspace, so it
  takes the Default arm.
  """
  # @canonical capability:scope-project-resolution aka:default_project_id,project_id,dataset_id,scope_opts
  @spec scope_project_id(keyword()) :: binary() | nil
  def scope_project_id(opts) when is_list(opts) do
    case {Keyword.get(opts, :project_id), Keyword.get(opts, :workspace_id)} do
      {project_id, _workspace} when is_binary(project_id) -> project_id
      {_absent, workspace} when is_binary(workspace) -> nil
      {_absent, _unresolved} -> scope_default_project_id()
    end
  end

  defp scope_default_project_id do
    case get_default_project() do
      %Project{id: id} -> id
      _ -> nil
    end
  end

  @doc "Fetch a Workspace by its slug, or nil."
  @spec get_workspace_by_slug(String.t()) :: Workspace.t() | nil
  def get_workspace_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Workspace, slug: slug)
  end

  @doc "Fetch a Workspace by its id, or nil. `nil` or malformed id returns nil."
  @spec get_workspace_by_id(binary() | nil) :: Workspace.t() | nil
  def get_workspace_by_id(nil), do: nil

  def get_workspace_by_id(id) when is_binary(id) do
    # Guard the :binary_id cast: a non-UUID id would raise Ecto.CastError → 500
    # the moment a caller wires a raw :id path param in. A malformed id matches
    # no row → nil, matching the guarded siblings (auth, media, webhooks, …).
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Workspace, uuid)
    end
  end

  # ── Workspace theme (ts-w4e) ──────────────────────────────────────────────
  #
  # A workspace's THEME IDENTITY is one orthogonal switch of the theme system
  # (the other is light/dark mode, owned entirely client-side). It persists in
  # the `settings` jsonb bag under `"theme"` and is resolved server-side so the
  # reader / Studio / email stamp it with no flash and no client round-trip.
  #
  # The theme allowlist is the GENERATED theme list — `TokensGen.themes/0`, which
  # design/emit.mjs derives by looping `design/themes/*.json` (charter D33: adding
  # theme N+1 = one new file, and every generated surface — including this one —
  # grows by exactly one id). It is a COMPILE-TIME generated module, not a runtime
  # read of the asset files, so validation still never depends on shipped assets
  # being present; a workspace pinned to a since-removed theme degrades to the
  # default (workspace_theme/1), not a 500.
  @default_theme "evergreen"

  @doc "The theme ids the compiler knows (the picker's option list); one per generated theme."
  @spec known_themes() :: [String.t()]
  def known_themes,
    do: Enum.map(Barkpark.PortableDoc.Render.TokensGen.themes(), &Atom.to_string/1)

  @doc "The baked-in default theme id — the `:root` palette every surface ships."
  @spec default_theme() :: String.t()
  def default_theme, do: @default_theme

  @doc """
  Resolve a workspace's theme id from its `settings` bag.

  Returns the stored `settings["theme"]` when it is a KNOWN theme id, else the
  default (`"evergreen"`). Guards a `nil` workspace and a workspace whose
  `settings` is nil/not-a-map (a legacy row read before the column backfilled)
  → the default. A workspace with no theme set therefore renders exactly as it
  did before this feature existed.
  """
  @spec workspace_theme(Workspace.t() | nil) :: String.t()
  def workspace_theme(%Workspace{settings: settings}) when is_map(settings) do
    # `known_themes/0` is a function call (a generated list), so the membership
    # test is a function-body check, not a module-attribute guard.
    case settings["theme"] do
      theme when is_binary(theme) -> if theme in known_themes(), do: theme, else: @default_theme
      _ -> @default_theme
    end
  end

  def workspace_theme(_), do: @default_theme

  @doc """
  Persist a workspace's theme id into its `settings` bag.

  Accepts a `%Workspace{}` struct or a workspace id binary. Rejects an unknown
  theme id with `{:error, :unknown_theme}` (the picker only offers known ids;
  this is the server-side gate against a forged value). Merges into the existing
  `settings` map so unrelated preferences are preserved. A missing/malformed id
  returns `{:error, :not_found}` without touching the DB.
  """
  @spec set_workspace_theme(Workspace.t() | binary(), String.t()) ::
          {:ok, Workspace.t()} | {:error, :unknown_theme | :not_found | Ecto.Changeset.t()}
  def set_workspace_theme(workspace_or_id, theme) when is_binary(theme) do
    # Theme membership is a generated-list check (known_themes/0), so it can no
    # longer live in a guard — validate first, then dispatch on the target shape.
    # Validating before the DB lookup preserves the old guard-first semantics:
    # an unknown theme is rejected without ever touching the row.
    if theme in known_themes() do
      do_set_workspace_theme(workspace_or_id, theme)
    else
      {:error, :unknown_theme}
    end
  end

  def set_workspace_theme(_workspace_or_id, _theme), do: {:error, :unknown_theme}

  defp do_set_workspace_theme(%Workspace{} = workspace, theme) do
    settings = Map.put(workspace.settings || %{}, "theme", theme)

    workspace
    |> Workspace.changeset(%{
      slug: workspace.slug,
      name: workspace.name,
      settings: settings
    })
    |> Repo.update()
  end

  defp do_set_workspace_theme(id, theme) when is_binary(id) do
    case get_workspace_by_id(id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> do_set_workspace_theme(workspace, theme)
    end
  end

  defp do_set_workspace_theme(_workspace_or_id, _theme), do: {:error, :not_found}

  # ── Workspace plugin enablement (ssp-w1-plugin-enablement) ────────────────
  #
  # The per-workspace SURFACING overrides for plugins live in the same
  # `settings` jsonb bag as `theme`, under the `"plugins"` key. These two
  # accessors mirror `workspace_theme/1` / `set_workspace_theme/2` exactly:
  # read guards a nil/legacy row to the empty map; write merges into `settings`
  # so the theme (and any other preference) is preserved. The resolution logic
  # — merging these overrides with each plugin's declaration defaults — lives in
  # `Barkpark.Plugins.Enablement.effective/1`, NOT here; this module only
  # persists and reads back the raw override map.

  @doc """
  Read a workspace's raw plugin-override map from its `settings` bag.

  Returns `settings["plugins"]` when it is a map, else `%{}`. Guards a `nil`
  workspace and a workspace whose `settings` is nil/not-a-map (a legacy row) →
  `%{}`. The map shape is
  `%{"<plugin>" => %{"enabled" => bool, "placement" => "main"|"plugins"|"top_menu"}}`;
  interpreting it against the plugin declarations is `Enablement.effective/1`'s job.
  """
  @spec workspace_plugin_settings(Workspace.t() | nil) :: map()
  def workspace_plugin_settings(%Workspace{settings: settings}) when is_map(settings) do
    case settings["plugins"] do
      plugins when is_map(plugins) -> plugins
      _ -> %{}
    end
  end

  def workspace_plugin_settings(_), do: %{}

  @doc """
  Persist a workspace's plugin-override map into its `settings` bag.

  Accepts a `%Workspace{}` struct or a workspace id binary. Merges into the
  existing `settings` map under the `"plugins"` key so the theme and unrelated
  preferences are preserved. A non-map `plugins` value returns
  `{:error, :invalid_plugins}` without touching the DB; a missing workspace
  returns `{:error, :not_found}`.
  """
  @spec set_workspace_plugin_settings(Workspace.t() | binary(), map()) ::
          {:ok, Workspace.t()} | {:error, :invalid_plugins | :not_found | Ecto.Changeset.t()}
  def set_workspace_plugin_settings(workspace_or_id, plugins) when is_map(plugins) do
    do_set_workspace_plugin_settings(workspace_or_id, plugins)
  end

  def set_workspace_plugin_settings(_workspace_or_id, _plugins), do: {:error, :invalid_plugins}

  defp do_set_workspace_plugin_settings(%Workspace{} = workspace, plugins) do
    settings = Map.put(workspace.settings || %{}, "plugins", plugins)

    workspace
    |> Workspace.changeset(%{
      slug: workspace.slug,
      name: workspace.name,
      settings: settings
    })
    |> Repo.update()
  end

  defp do_set_workspace_plugin_settings(id, plugins) when is_binary(id) do
    case get_workspace_by_id(id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> do_set_workspace_plugin_settings(workspace, plugins)
    end
  end

  defp do_set_workspace_plugin_settings(_workspace_or_id, _plugins), do: {:error, :not_found}

  # ── Workspace chat settings (connectors D205 — per-workspace execution profile) ──
  #
  # The per-workspace CHAT preferences live in the same `settings` jsonb bag as
  # `theme` and `plugins`, under the `"chat"` key. These two accessors mirror
  # `workspace_plugin_settings/1` / `set_workspace_plugin_settings/2` exactly:
  # read guards a nil/legacy row to the empty map; write merges into `settings`
  # so the theme, plugin overrides, and any other preference are preserved.
  # Interpreting `"execution_profile"` (`"cloud" | "self_hosted"`; anything else
  # counts as unset → the global config → :self_hosted, fail-safe) is
  # `BarkparkWeb.Studio.ClaudeChat`'s job — this module only persists and reads
  # back the raw map.

  @doc """
  Read a workspace's raw chat-settings map from its `settings` bag.

  Returns `settings["chat"]` when it is a map, else `%{}`. Guards a `nil`
  workspace and a workspace whose `settings` is nil/not-a-map (a legacy row) →
  `%{}`. The map shape is `%{"execution_profile" => "cloud" | "self_hosted"}`;
  interpreting it against the global execution-profile config is
  `BarkparkWeb.Studio.ClaudeChat`'s job.
  """
  @spec workspace_chat_settings(Workspace.t() | nil) :: map()
  def workspace_chat_settings(%Workspace{settings: settings}) when is_map(settings) do
    case settings["chat"] do
      chat when is_map(chat) -> chat
      _ -> %{}
    end
  end

  def workspace_chat_settings(_), do: %{}

  @doc """
  Persist a workspace's chat-settings map into its `settings` bag.

  Accepts a `%Workspace{}` struct or a workspace id binary. Merges into the
  existing `settings` map under the `"chat"` key so the theme and unrelated
  preferences are preserved. A non-map `chat` value returns
  `{:error, :invalid_chat_settings}` without touching the DB; a missing
  workspace returns `{:error, :not_found}`.
  """
  @spec set_workspace_chat_settings(Workspace.t() | binary(), map()) ::
          {:ok, Workspace.t()}
          | {:error, :invalid_chat_settings | :not_found | Ecto.Changeset.t()}
  def set_workspace_chat_settings(workspace_or_id, chat) when is_map(chat) do
    do_set_workspace_chat_settings(workspace_or_id, chat)
  end

  def set_workspace_chat_settings(_workspace_or_id, _chat), do: {:error, :invalid_chat_settings}

  defp do_set_workspace_chat_settings(%Workspace{} = workspace, chat) do
    settings = Map.put(workspace.settings || %{}, "chat", chat)

    workspace
    |> Workspace.changeset(%{
      slug: workspace.slug,
      name: workspace.name,
      settings: settings
    })
    |> Repo.update()
  end

  defp do_set_workspace_chat_settings(id, chat) when is_binary(id) do
    case get_workspace_by_id(id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> do_set_workspace_chat_settings(workspace, chat)
    end
  end

  defp do_set_workspace_chat_settings(_workspace_or_id, _chat), do: {:error, :not_found}

  # ── Pull provenance (PDS-D15/D16 — where pulled data came from) ────────────
  #
  # A dataset pulled from another server (`bp dev pull`) records WHERE it came
  # from, in the same `settings` jsonb bag as `theme` / `plugins` / `chat`,
  # under the `"pull_provenance"` key. Zero migration.
  #
  # Unlike those three this bag is TWO levels deep — keyed by DATASET SLUG —
  # because one workspace holds sibling datasets that are pulled independently
  # and must never clobber each other's stamp:
  #
  #     settings["pull_provenance"]["production"] =>
  #       %{"source_server" => …, "source_workspace" => …, "source_dataset" => …,
  #         "exported_at" => …, "profile" => …, "pulled_at" => …}
  #
  # The stamp is also the KEY the boot-time plugin bootstrap guard reads
  # (`Barkpark.Plugins.Bootstrap`): a schema row living in a stamped
  # (workspace, dataset) slot is pulled data, so bootstrap logs drift instead of
  # overwriting it.

  @doc """
  Read the pull-provenance stamp for one dataset slug of a workspace.

  Returns the stored map when this workspace carries a stamp for `dataset_slug`,
  else `%{}`. Guards a `nil` workspace, a workspace whose `settings` is
  nil/not-a-map (a legacy row read before the column backfilled), a
  non-map `"pull_provenance"` bag and a non-binary slug — every one degrades to
  `%{}` rather than raising, because this read sits on the boot path.
  """
  @spec pull_provenance(Workspace.t() | nil, binary() | nil) :: map()
  def pull_provenance(%Workspace{settings: settings}, dataset_slug)
      when is_map(settings) and is_binary(dataset_slug) do
    with bag when is_map(bag) <- settings["pull_provenance"],
         stamp when is_map(stamp) <- bag[dataset_slug] do
      stamp
    else
      _ -> %{}
    end
  end

  def pull_provenance(_workspace, _dataset_slug), do: %{}

  @doc """
  Read the whole pull-provenance bag of a workspace (`%{slug => stamp}`).

  Same guards as `pull_provenance/2` → `%{}` on anything unexpected.
  """
  @spec pull_provenance(Workspace.t() | nil) :: map()
  def pull_provenance(%Workspace{settings: settings}) when is_map(settings) do
    case settings["pull_provenance"] do
      bag when is_map(bag) -> bag
      _ -> %{}
    end
  end

  def pull_provenance(_workspace), do: %{}

  # ─── The pull-provenance guard predicate (PDS-D21/D22, PDS-D125/D126) ──────
  #
  # ONE home, TWO boot-time writers. `Plugins.Bootstrap.upsert_one/3` walks the
  # plugin registry; `Content.TagRegistry.register_attrs!/2` writes the core
  # `tag` schema straight through, outside that walk and outside
  # `SchemaBootstrap`'s rescue. Both land on `Content.upsert_schema/2`, which
  # reads first and UPDATES in place, so both can clobber a pulled row — and
  # they clobber DIFFERENT column sets, because `Ecto.Changeset.cast/3` only
  # touches keys PRESENT in the attrs map (Bootstrap builds attrs from
  # `Map.from_struct` and reverts eight; TagRegistry declares five keys and
  # reverts four). The write-shape differs; the question "is the row this
  # upsert would match pulled data?" does not. It is answered exactly once,
  # here, and a second copy of it would be the fork the canonical-impl doctrine
  # exists to prevent.
  #
  # WHAT THE READ ACTUALLY MATCHES. `Content.get_schema/3` on empty opts narrows
  # to the DEFAULT project's dataset_id (`resolve_read_dataset_id` →
  # `read_default_project_id([])`), so this is DEFAULT-DATASET-SLOT matching:
  # a properly-backfilled FOREIGN row is never matched, a row sitting in the
  # Default slot is. Post-PDS-D9 the Default slot IS the pulled workspace.
  #
  # WHAT CALLERS DO WITH IT IS THEIR OWN CONTRACT. This predicate answers a
  # question; it does not decide the skip. Bootstrap skips the whole upsert
  # (insert included — its rows are plugin-declared and a missing one is
  # log-and-continue). TagRegistry skips the UPDATE only and still inserts when
  # absent, because PDS-D12 puts it outside the boot rescue precisely so a
  # missing core `tag` schema fails the boot closed rather than booting a system
  # whose publish wall can resolve nothing (PDS-D126).

  @doc """
  The schema row a boot-time upsert of `name`/`dataset` would MATCH, when that
  row is pull-provenance-stamped data — else `nil`.

  Returns the `%Barkpark.Content.SchemaDefinition{}` itself (not a boolean) so a
  caller that wants to return the surviving row can do so without a second read;
  `pulled_schema_row?/2` is the boolean face of the same answer.

  A row counts as pulled when it exists, carries a `workspace_id`, and that
  workspace carries a non-empty `pull_provenance` stamp for the row's own
  dataset SLUG (a stamp on a sibling dataset does NOT cover this one).

  Fail-OPEN by design: any raise from the read degrades to `nil` (= "not
  pulled", proceed unguarded). This sits on the boot path, so the guard's own
  read must never be what breaks a boot — losing the guard is recoverable, a
  boot loop is not.
  """
  @spec pulled_schema_row(term(), term()) :: Content.SchemaDefinition.t() | nil
  # @canonical capability:pull-provenance-schema-guard aka:pulled_row,provenance_covered,clobber guard,schema bootstrap guard
  def pulled_schema_row(name, dataset) when is_binary(name) and is_binary(dataset) do
    case Content.get_schema(name, dataset) do
      {:ok, %Content.SchemaDefinition{} = existing} ->
        if provenance_covered?(existing, dataset), do: existing, else: nil

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning(
        "Tenancy.pulled_schema_row: pull-provenance guard read failed for " <>
          "#{inspect(name)}/#{inspect(dataset)} — proceeding unguarded: #{Exception.message(e)}"
      )

      nil
  end

  def pulled_schema_row(_name, _dataset), do: nil

  @doc """
  Boolean face of `pulled_schema_row/2`: does a boot-time upsert of
  `name`/`dataset` match a pull-provenance-stamped row?
  """
  @spec pulled_schema_row?(term(), term()) :: boolean()
  def pulled_schema_row?(name, dataset), do: not is_nil(pulled_schema_row(name, dataset))

  defp provenance_covered?(%Content.SchemaDefinition{workspace_id: nil}, _dataset), do: false

  defp provenance_covered?(%Content.SchemaDefinition{} = existing, dataset) do
    # The row's own `dataset` STRING is the dataset SLUG the stamp is keyed by.
    slug = existing.dataset || dataset

    existing.workspace_id
    |> get_workspace_by_id()
    |> pull_provenance(slug)
    |> map_size()
    |> Kernel.>(0)
  end

  @doc """
  Persist the pull-provenance stamp for ONE dataset slug of a workspace.

  Accepts a `%Workspace{}` struct or a workspace id binary. Merges into the
  existing `settings` map under `"pull_provenance"` and, INSIDE that, under
  `dataset_slug` — so the theme, plugin overrides, chat prefs AND every sibling
  dataset's stamp survive. A non-map `provenance` or a non-binary slug returns
  `{:error, :invalid_provenance}` without touching the DB; a missing workspace
  returns `{:error, :not_found}`.

  CLEARING a stamp is writing an EMPTY map: `set_pull_provenance(ws, slug, %{})`.
  That is the supported escape hatch out of the `Plugins.Bootstrap` guard — a
  stamped slot never takes a plugin schema update again, so the operator needs a
  way back. It is pinned by `bootstrap_guard_test.exs` ("CLEARING the stamp is a
  real escape hatch"). There is no CLI/HTTP surface for it yet
  (`pds-bl-clear-pull-provenance`); a remote console is the only front door.
  """
  @spec set_pull_provenance(Workspace.t() | binary(), binary(), map()) ::
          {:ok, Workspace.t()}
          | {:error, :invalid_provenance | :not_found | Ecto.Changeset.t()}
  def set_pull_provenance(workspace_or_id, dataset_slug, provenance)
      when is_binary(dataset_slug) and is_map(provenance) do
    do_set_pull_provenance(workspace_or_id, dataset_slug, provenance)
  end

  def set_pull_provenance(_workspace_or_id, _dataset_slug, _provenance),
    do: {:error, :invalid_provenance}

  defp do_set_pull_provenance(%Workspace{} = workspace, dataset_slug, provenance) do
    bag = pull_provenance(workspace)

    settings =
      Map.put(
        workspace.settings || %{},
        "pull_provenance",
        Map.put(bag, dataset_slug, provenance)
      )

    workspace
    |> Workspace.changeset(%{
      slug: workspace.slug,
      name: workspace.name,
      settings: settings
    })
    |> Repo.update()
  end

  defp do_set_pull_provenance(id, dataset_slug, provenance) when is_binary(id) do
    case get_workspace_by_id(id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> do_set_pull_provenance(workspace, dataset_slug, provenance)
    end
  end

  defp do_set_pull_provenance(_workspace_or_id, _dataset_slug, _provenance),
    do: {:error, :not_found}

  @doc "Fetch a Project by its id, or nil. `nil` or malformed id returns nil."
  @spec get_project_by_id(binary() | nil) :: Project.t() | nil
  def get_project_by_id(nil), do: nil

  def get_project_by_id(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Project, uuid)
    end
  end

  @doc """
  Resolve the `{workspace_slug, project_slug}` pair for a record carrying
  `workspace_id` / `project_id` columns (a Document, Webhook, …). Falls back
  to the default slug (`"default"`) when an id is `nil` (pre-tenancy /
  unscoped) or when the row no longer exists — keeping the emitted sync-tag
  namespace well-formed in every path.
  """
  @spec resolve_scope_slugs(binary() | nil, binary() | nil) :: {String.t(), String.t()}
  def resolve_scope_slugs(workspace_id, project_id) do
    ws_slug =
      case get_workspace_by_id(workspace_id) do
        %Workspace{slug: slug} -> slug
        nil -> @default_slug
      end

    project_slug =
      case get_project_by_id(project_id) do
        %Project{slug: slug} -> slug
        nil -> @default_slug
      end

    {ws_slug, project_slug}
  end

  @doc """
  Fetch a Project by its Workspace slug + Project slug. Returns nil when
  either the Workspace or the Project is absent.
  """
  @spec get_project(String.t(), String.t()) :: Project.t() | nil
  def get_project(ws_slug, project_slug)
      when is_binary(ws_slug) and is_binary(project_slug) do
    query =
      from p in Project,
        join: w in Workspace,
        on: p.workspace_id == w.id,
        where: w.slug == ^ws_slug and p.slug == ^project_slug

    Repo.one(query)
  end

  @doc "List all Workspaces, ordered by slug."
  @spec list_workspaces() :: [Workspace.t()]
  def list_workspaces do
    Repo.all(from w in Workspace, order_by: w.slug)
  end

  @doc """
  True when MORE THAN ONE workspace exists — i.e. the install is multi-tenant.

  The content-edge projection write path uses this to decide whether a doc with
  an UNRESOLVABLE workspace may have its edges materialised globally. In a
  single-tenant install (zero/one workspace) a nil workspace is the documented
  legacy back-compat row, so a global edge is correct. In a MULTI-tenant install
  a nil workspace must FAIL CLOSED (mirror `Scope.scope_to_workspace/3`): a
  globally-resolved slug can collide with another tenant's same-slug doc and
  durably store a cross-tenant `content_edges` row. Cheap: a single bounded
  COUNT (`LIMIT 2`) — never returns true on a fresh single-workspace seed.
  """
  @spec multi_tenant?() :: boolean()
  def multi_tenant? do
    Repo.aggregate(from(w in Workspace, limit: 2), :count, :id) > 1
  rescue
    # A read failure (no DB, mid-migration) must never crash a projection
    # lifecycle hook. Degrade to the SAFE multi-tenant posture: fail closed.
    _ -> true
  end

  @doc """
  List the Workspaces a principal is a MEMBER of, ordered by slug.

  RELOCATED (`task-e7571b83f9a101fd`): the query itself now lives in
  `Barkpark.Tenancy.Auth.list_workspaces_for/1`, the chokepoint that owns the
  `(principal_id, workspace_id, principal_type)` membership keying. This is a
  pure delegation kept for the existing `barkpark_web` call sites — it adds no
  normalisation, no filtering and no clause of its own, so totality and the
  fail-closed posture are exactly `Tenancy.Auth`'s. Read the contract, the
  totality rules and the fail-open shape this must NOT become there.
  """
  @spec list_workspaces_for(User.t() | ApiToken.t() | binary() | nil) :: [Workspace.t()]
  defdelegate list_workspaces_for(principal), to: TenancyAuth

  @doc "List all Projects under a Workspace (accepts a struct or a workspace id)."
  @spec list_projects(Workspace.t() | binary()) :: [Project.t()]
  def list_projects(%Workspace{id: ws_id}), do: list_projects(ws_id)

  def list_projects(ws_id) when is_binary(ws_id) do
    # Order the canonical `default`-slug project FIRST, then the rest
    # alphabetically. This makes every consumer that takes the first project
    # (web's `projects[0]` from `listProjects`, the switcher, studio mount via
    # `initial_project/1`) resolve the same canonical default. The boolean
    # `slug = 'default'` sorts DESC (true before false), then `slug` ASC.
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^ws_id,
        order_by: [desc: fragment("? = 'default'", p.slug), asc: p.slug]
    )
  end

  @doc "Create a Workspace from attrs."
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a Project under the given Workspace (struct or id). The workspace_id
  in `attrs` is overridden by the resolved workspace.
  """
  @spec create_project(Workspace.t() | binary(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(%Workspace{id: ws_id}, attrs), do: create_project(ws_id, attrs)

  def create_project(ws_id, attrs) when is_binary(ws_id) do
    %Project{}
    |> Project.changeset(Map.put(attrs, :workspace_id, ws_id))
    |> Repo.insert()
  end

  @doc """
  Bootstrap a brand-new, immediately-usable Workspace for the creating token,
  atomically (single `Repo.transaction`):

    1. the Workspace itself,
    2. a Membership binding the api_token as `"owner"`,
    3. a Default Project, and
    4. a "production" Dataset under that project.

  `attrs` carries `:name` (required) and an optional `:slug` — when the slug is
  absent it is derived from the name (`slugify/1`). `owner_token` is the
  authenticated `%ApiToken{}` (or its id) calling POST /api/workspaces.

  Returns `{:ok, workspace}` with the freshly-created Default Project
  preloaded under `workspace.projects` (and the Dataset under that project's
  `:datasets`) so the controller can render them without a reload, or
  `{:error, changeset}`. A duplicate workspace slug surfaces as a clean
  changeset error on the unique constraint.
  """
  @spec create_workspace_with_owner(map(), User.t() | ApiToken.t() | binary()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace_with_owner(attrs, %ApiToken{id: principal_id} = token),
    do:
      do_create_workspace_with_owner(
        attrs,
        principal_id,
        "api_token",
        resolvable_owner_user_id(token)
      )

  # A User creator gets a `principal_type: "user"` owner-membership row, so
  # `authorize(%User{}, workspace, …)` can see the grant — otherwise the creator
  # would be locked out of the workspace they just made. Kept SEPARATE from the
  # raw-binary head (pinned to "api_token"); a bare id carries no kind.
  def create_workspace_with_owner(attrs, %User{id: principal_id}) when is_binary(principal_id),
    do: do_create_workspace_with_owner(attrs, principal_id, "user", nil)

  def create_workspace_with_owner(attrs, principal_id) when is_binary(principal_id),
    do: do_create_workspace_with_owner(attrs, principal_id, "api_token", nil)

  # `co_owner_user_id` is the HUMAN behind an owning api_token, when there is
  # one — see `resolvable_owner_user_id/1`. It gets a SECOND owner-membership
  # row typed "user" in the same transaction, so the person who created the
  # workspace over HTTP is a member of it. nil (a CI/bootstrap token with no
  # human, or a user/bare-id creator) writes exactly one row, as before.
  defp do_create_workspace_with_owner(attrs, principal_id, principal_type, co_owner_user_id)
       when is_binary(principal_id) and is_binary(principal_type) do
    ws_attrs = put_derived_slug(attrs)

    if default_singleton_slug?(slug_value(ws_attrs)) do
      {:error, singleton_slug_error(ws_attrs)}
    else
      do_create_owned_workspace(ws_attrs, principal_id, principal_type, co_owner_user_id)
    end
  end

  @doc """
  True when `slug` is THE instance-default singleton slug — the one
  `get_default_workspace/0` resolves, and the one `singleton_slug_error/1`
  refuses a principal from claiming.

  EXPORTED so a SECOND write path can consult the rule instead of restating it
  (task-545166efceb1bc91). `WorkspaceBundle`'s import restores the root
  `workspaces` row by raw `COPY`, which reaches neither this module's guard nor
  `Workspace.changeset/2` — it asks HERE rather than comparing against its own
  copy of the string, so a change to the singleton's identity moves both
  chokepoints at once.
  """
  @spec default_singleton_slug?(term()) :: boolean()
  def default_singleton_slug?(slug), do: slug == @default_slug

  @doc """
  Every workspace slug a PRINCIPAL may never end up holding: the
  instance-default singleton (`default_singleton_slug?/1`) plus
  `Workspace.reserved_slugs/0` — the routing-prefix list
  `Workspace.changeset/2` enforces with `validate_exclusion`.

  ONE list, two enforcement points. The changeset owns the ordinary create/
  update path; `WorkspaceBundle`'s raw-`COPY` import consults this to close the
  same door on the path a changeset never sees. Composed, never copied.
  """
  @spec reserved_workspace_slugs() :: [String.t()]
  def reserved_workspace_slugs, do: [@default_slug | Workspace.reserved_slugs()]

  @doc "True when `slug` is in `reserved_workspace_slugs/0`."
  @spec reserved_workspace_slug?(term()) :: boolean()
  def reserved_workspace_slug?(slug) when is_binary(slug),
    do: slug in reserved_workspace_slugs()

  def reserved_workspace_slug?(_other), do: false

  # ── Instance-singleton seat guard (task-94a6ed8ced1fc547) ───────────────────
  #
  # `get_default_workspace/0` identifies a security-relevant SINGLETON by a
  # mutable string — `Repo.get_by(Workspace, slug: @default_slug)`. Whoever holds
  # that slug IS the instance default: `AssignDefaultScope` binds every flat
  # route to it, and `Content.WriteScope.resolve_write_scope/1` stamps an
  # UNSCOPED WRITE with it. So while the seat is vacant, taking the slug takes
  # the seat, and an unscoped write lands in the claimant's workspace.
  #
  # The seat goes vacant in NORMAL operation, not only via a destructive admin
  # action: `SupportResetDefaultWorkspaceStep` deletes it and the following
  # `SupportAdminTokenStep` re-mints it — the seat is vacant BETWEEN the two, and
  # the bracket tolerates an absent workspace so re-runs converge.
  #
  # GUARDED HERE — after `put_derived_slug/1`, on the ONE chokepoint every
  # ownership-claiming path funnels through — because the slug is DERIVED as
  # often as it is typed. `slugify("Default") == "default"`, so three of the four
  # claim paths never send a `slug` field at all:
  #
  #   * POST /api/workspaces {"slug":"default"}              explicit
  #   * POST /api/workspaces {"name":"Default"}              derived
  #   * Studio create-workspace (live/studio/.../scope.ex)   derived
  #   * studio_chrome.ex                                     derived
  #
  # A controller-level check on `params["slug"]` sees only the first.
  #
  # `create_workspace/1` is deliberately NOT guarded: it is the INTERNAL creator
  # that legitimately mints the singleton (`Seeds.Shared.ensure_default_scope/0`,
  # `mix frt.seed`), and it is how the support bracket recovers. The line this
  # guard draws is exactly "a PRINCIPAL is claiming ownership of a new
  # workspace" — which must never yield the singleton — versus "the SYSTEM is
  # establishing its own default".
  #
  # The refusal is a CHANGESET error, so it surfaces as the same 422 a duplicate
  # slug already produces: the Studio handlers' existing `{:error, changeset}`
  # branches and the support box's `case "$code" in 2*|409|422)` tolerance both
  # keep working untouched.
  #
  # RESIDUE, stated rather than implied: renaming a workspace INTO the slug
  # bypasses this, since `Workspace.changeset/2` casts `:slug`. There is no
  # `update_workspace/2` and no HTTP update route today, so it is unreachable —
  # but the end state is to stop identifying the singleton by a claimable string
  # at all, which is a data-model change this guard does not attempt.
  defp singleton_slug_error(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Ecto.Changeset.add_error(
      :slug,
      "is reserved for the instance default workspace and cannot be claimed"
    )
    |> Map.put(:action, :insert)
  end

  defp do_create_owned_workspace(ws_attrs, principal_id, principal_type, co_owner_user_id) do
    Repo.transaction(fn ->
      with {:ok, workspace} <- create_workspace(ws_attrs),
           {:ok, _membership} <-
             TenancyAuth.create_membership(workspace.id, principal_id, "owner", principal_type),
           {:ok, _user_membership} <-
             maybe_create_user_owner_membership(workspace.id, co_owner_user_id),
           {:ok, project} <-
             create_project(workspace, %{
               slug: @default_project_slug,
               name: @default_project_name
             }),
           {:ok, dataset} <-
             create_dataset(project, %{
               slug: @production_dataset_slug,
               name: @production_dataset_slug
             }) do
        _ = dataset
        %{workspace | projects: [project]}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # The user principal an owning api_token stands for, or nil.
  #
  # Mirrors `BarkparkWeb.Plugs.ResolveTokenOwner`: a token with a non-nil
  # `owner_user_id` naming a LOADABLE user resolves to that user; a NULL
  # `owner_user_id` or a dangling FK resolves to nil. CONDITIONAL by
  # construction — a CI/bootstrap token legitimately has no human, and a
  # NULL/placeholder membership row is never written.
  #
  # The plug's precedence rule (a live account session always outranks a
  # token's owner) does not apply here: `POST /api/workspaces` rides
  # `[:api, :require_token]`, which resolves no session and assigns no
  # `:current_user`, so the token's owner is the only human on the request.
  defp resolvable_owner_user_id(%ApiToken{owner_user_id: owner_id}) when is_binary(owner_id) do
    case Repo.get(User, owner_id) do
      %User{id: id} -> id
      _ -> nil
    end
  end

  defp resolvable_owner_user_id(%ApiToken{}), do: nil

  defp maybe_create_user_owner_membership(_workspace_id, nil), do: {:ok, nil}

  defp maybe_create_user_owner_membership(workspace_id, user_id) when is_binary(user_id),
    do: TenancyAuth.create_membership(workspace_id, user_id, "owner", "user")

  @doc """
  Grant the HUMAN owner of an owning api_token a matching `"user"`-typed owner
  membership on every workspace that has an api_token owner-membership and no
  user-typed membership for that same human yet — the backfill for every
  workspace created before `create_workspace_with_owner/2` bound the creator.

  Those workspaces are unreachable for their creator as a `%User{}`
  (`member?/2` false, `list_workspaces_for/1` empty) and there is no membership
  verb anywhere in the product, so the state cannot be repaired by using
  Barkpark — only by this.

  IDEMPOTENT: the unique index on
  `(workspace_id, principal_type, principal_id)` makes a re-run a no-op, and
  rows that already exist are skipped before insert, so a second run reports
  `granted: 0`.

  HONEST ABOUT WHAT IT COULD NOT DO: returns
  `%{granted: [...], unresolved: [...]}` where `granted` carries
  `{workspace_id, user_id}` for every row written and `unresolved` carries
  `{workspace_id, reason}` for every api_token-owned workspace left without a
  human — `:no_owner_user` (the owning token has a NULL `owner_user_id`),
  `:dangling_owner_user`, or `:insert_failed`. An unresolved workspace is NOT a
  failure: a CI/bootstrap token has no human by design.

  `:dangling_owner_user` is a fail-closed arm, not an expected outcome — the FK
  is `on_delete: :nilify_all` (migration 20260708130000), so deleting a user
  NULLs the column rather than orphaning it. It mirrors `ResolveTokenOwner`,
  which likewise refuses to invent a user it cannot load.
  """
  @spec backfill_user_owner_memberships() :: %{
          granted: [{binary(), binary()}],
          unresolved: [{binary(), atom()}]
        }
  def backfill_user_owner_memberships do
    token_owned =
      Repo.all(
        from m in Membership,
          join: t in ApiToken,
          on: t.id == m.principal_id,
          where: m.principal_type == "api_token" and m.role == "owner",
          select: {m.workspace_id, t.owner_user_id}
      )

    token_owned
    |> Enum.reduce(%{granted: [], unresolved: []}, fn {ws_id, owner_user_id}, acc ->
      # Prepend + reverse at the end: `acc.list ++ [x]` walks the whole
      # accumulator on every workspace, and this runs over EVERY owner
      # membership row on the box.
      case backfill_one(ws_id, owner_user_id) do
        {:granted, user_id} -> %{acc | granted: [{ws_id, user_id} | acc.granted]}
        :already -> acc
        {:unresolved, reason} -> %{acc | unresolved: [{ws_id, reason} | acc.unresolved]}
      end
    end)
    |> then(&%{granted: Enum.reverse(&1.granted), unresolved: Enum.reverse(&1.unresolved)})
  end

  defp backfill_one(_ws_id, nil), do: {:unresolved, :no_owner_user}

  defp backfill_one(ws_id, owner_user_id) do
    cond do
      is_nil(Repo.get(User, owner_user_id)) ->
        {:unresolved, :dangling_owner_user}

      Repo.exists?(
        from m in Membership,
          where:
            m.workspace_id == ^ws_id and m.principal_type == "user" and
                m.principal_id == ^owner_user_id
      ) ->
        :already

      true ->
        case TenancyAuth.create_membership(ws_id, owner_user_id, "owner", "user") do
          {:ok, _} -> {:granted, owner_user_id}
          {:error, _changeset} -> {:unresolved, :insert_failed}
        end
    end
  end

  @doc """
  Create a Project under `workspace` PLUS its "production" Dataset, atomically.
  `attrs` carries `:name` (required) and an optional `:slug` (derived from the
  name when absent). Returns `{:ok, project}`, or `{:error, changeset}`
  (project slug collides within the workspace → clean unique-constraint error).
  The "production" Dataset is created in the same transaction.
  """
  @spec create_project_with_dataset(Workspace.t() | binary(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project_with_dataset(%Workspace{id: ws_id}, attrs),
    do: create_project_with_dataset(ws_id, attrs)

  def create_project_with_dataset(ws_id, attrs) when is_binary(ws_id) do
    project_attrs = put_derived_slug(attrs)

    Repo.transaction(fn ->
      with {:ok, project} <- create_project(ws_id, project_attrs),
           {:ok, _dataset} <-
             create_dataset(project, %{
               slug: @production_dataset_slug,
               name: @production_dataset_slug
             }) do
        project
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Ensure `attrs` carries a :slug, deriving it from :name when absent/blank.
  # Leaves an explicit slug untouched (the changeset validates its format).
  defp put_derived_slug(attrs) do
    case slug_value(attrs) do
      slug when is_binary(slug) and slug != "" ->
        attrs

      _ ->
        Map.put(attrs, slug_key(attrs), slugify(name_value(attrs)))
    end
  end

  defp slug_value(attrs), do: Map.get(attrs, :slug) || Map.get(attrs, "slug")
  defp name_value(attrs), do: Map.get(attrs, :name) || Map.get(attrs, "name") || ""
  defp slug_key(attrs), do: if(Map.has_key?(attrs, "name"), do: "slug", else: :slug)

  @doc """
  Slugify a name into a workspace/project slug: downcase, collapse any run of
  non-alphanumerics to a single hyphen, trim leading/trailing hyphens. Returns
  `""` for an all-symbol/blank input — the changeset's `validate_required` +
  `validate_format` then surface a clean error.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def slugify(_), do: ""

  # --- Datasets (Wave 2) ----------------------------------------------------
  #
  # A Dataset lives under a Project; it promotes the plain `dataset` string to
  # a row. Additive seam only — the string stays authoritative for now.

  @doc "Fetch a Dataset by its id, or nil. `nil` or malformed id returns nil."
  @spec get_dataset_by_id(binary() | nil) :: Dataset.t() | nil
  def get_dataset_by_id(nil), do: nil

  def get_dataset_by_id(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Dataset, uuid)
    end
  end

  @doc """
  Fetch a Dataset by its Project (struct or id) + slug. Returns nil when the
  Project has no Dataset with that slug.
  """
  @spec get_dataset(Project.t() | binary(), String.t()) :: Dataset.t() | nil
  def get_dataset(%Project{id: project_id}, slug), do: get_dataset(project_id, slug)

  def get_dataset(project_id, slug) when is_binary(project_id) and is_binary(slug) do
    Repo.get_by(Dataset, project_id: project_id, slug: slug)
  end

  @doc "List all Datasets under a Project (accepts a struct or a project id), the canonical `production` dataset first, then the rest alphabetically."
  @spec list_datasets(Project.t() | binary()) :: [Dataset.t()]
  def list_datasets(%Project{id: project_id}), do: list_datasets(project_id)

  def list_datasets(project_id) when is_binary(project_id) do
    # Order the canonical `production`-slug dataset FIRST, then the rest
    # alphabetically — the same idiom as `list_projects/1`'s `default` ordering.
    # Every consumer that takes the first dataset (the mobile cascade's
    # single-option auto-select, the switcher) resolves the same canonical
    # default. The boolean `slug = 'production'` sorts DESC (true before false),
    # then `slug` ASC.
    Repo.all(
      from d in Dataset,
        where: d.project_id == ^project_id,
        order_by: [desc: fragment("? = ?", d.slug, ^@production_dataset_slug), asc: d.slug]
    )
  end

  @doc """
  Create a Dataset under the given Project (struct or id). The project_id in
  `attrs` is overridden by the resolved project.
  """
  @spec create_dataset(Project.t() | binary(), map()) ::
          {:ok, Dataset.t()} | {:error, Ecto.Changeset.t()}
  def create_dataset(%Project{id: project_id}, attrs), do: create_dataset(project_id, attrs)

  def create_dataset(project_id, attrs) when is_binary(project_id) do
    %Dataset{}
    |> Dataset.changeset(Map.put(attrs, :project_id, project_id))
    # `on_conflict: :nothing` keeps a concurrent duplicate insert from ABORTING
    # the surrounding Postgres transaction (apply_mutations wraps this call). On
    # a hit the DB skips the row and Ecto STILL returns {:ok, struct} — but that
    # struct carries the changeset's autogenerated binary_id, NOT the existing
    # row's id, so it can't be trusted as "the persisted row". Callers that need
    # the real row (get_or_create_dataset) reload via get_dataset after :ok.
    # `conflict_target` matches the `datasets_project_id_slug_index` unique index
    # (project_id, slug).
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:project_id, :slug])
  end

  @doc """
  Fetch the Dataset with `slug` under `project` (struct or id), creating it
  (slug = name = slug) when absent. Returns `{:ok, dataset}` or
  `{:error, changeset}`. Tolerates a concurrent insert via `on_conflict:
  :nothing` (see `create_dataset/2`) — a duplicate insert is a no-op that does
  NOT abort the surrounding transaction, and we re-fetch the existing row. This
  matters because the call runs inside `apply_mutations`' `Repo.transaction`;
  letting the unique constraint raise would poison the whole transaction.
  """
  @spec get_or_create_dataset(Project.t() | binary(), String.t()) ::
          {:ok, Dataset.t()} | {:error, Ecto.Changeset.t() | :dataset_not_found}
  def get_or_create_dataset(%Project{id: project_id}, slug),
    do: get_or_create_dataset(project_id, slug)

  def get_or_create_dataset(project_id, slug)
      when is_binary(project_id) and is_binary(slug) do
    case get_dataset(project_id, slug) do
      %Dataset{} = dataset ->
        {:ok, dataset}

      nil ->
        case create_dataset(project_id, %{slug: slug, name: slug}) do
          # Insert returned :ok — but with `on_conflict: :nothing` a duplicate is
          # a SILENT no-op: Ecto hands back the changeset's struct carrying the
          # autogenerated (unpersisted) binary_id, NOT the existing row's id. We
          # can't distinguish "I inserted" from "conflict swallowed" by the id
          # alone, so always reload via get_dataset to return the row that's
          # actually in the DB. The conflict no longer aborts the surrounding
          # transaction, so this re-fetch is safe.
          {:ok, %Dataset{}} ->
            case get_dataset(project_id, slug) do
              %Dataset{} = dataset -> {:ok, dataset}
              nil -> {:error, :dataset_not_found}
            end

          # Changeset validation failed before reaching the DB (e.g. invalid
          # slug) — surface it; the transaction was never touched.
          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Resolve a bare dataset/scope STRING → its `dataset_id` under the seeded
  Default project, get-or-creating the dataset row. Returns the id, or nil when
  the Default project isn't seeded yet (fresh sandbox). Used by single-project
  surfaces (search-intel synonyms / crystals / merge-patterns) whose only scope
  key is the legacy STRING — the W2 dual-write threads the resolved id alongside
  it so the flipped `(surface, dataset_id, …)` uniques stay meaningful.
  """
  @spec default_project_dataset_id(String.t()) :: binary() | nil
  def default_project_dataset_id(slug) when is_binary(slug) do
    case get_default_project() do
      %Project{id: project_id} ->
        case get_or_create_dataset(project_id, slug) do
          {:ok, %Dataset{id: id}} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def default_project_dataset_id(_), do: nil

  # --- Workspace delete (obhg P0 + 0f7g P1) --------------------------------
  #
  # Deleting a workspace touches THREE classes of state:
  #
  #   1. Rows with side-effect cleanup (media_files → disk blob + CDN edge
  #      cache + Renditions + after_media_delete plugin hooks; documents →
  #      :after_delete plugin hooks). These MUST be deleted through the
  #      context functions so the hooks fire — a raw `Repo.delete(workspace)`
  #      that lets SQL CASCADE remove the row would leak blobs on disk/S3
  #      and miss plugin notifications.
  #
  #   2. Rows that are just rows (revisions, schema_definitions, webhooks,
  #      mutation_events, search_intel_events, search_intel_crystals,
  #      search_intel_merge_patterns, search_synonyms, paper_events). These
  #      can ride SQL CASCADE — there is nothing to clean up.
  #
  #   3. The workspace's own children (projects, datasets, memberships,
  #      api_tokens.workspace_id). Existing FKs already cascade or nilify
  #      these correctly.
  #
  # delete_workspace/1 walks class (1) explicitly, then `Repo.delete(workspace)`
  # cascades classes (2) and (3) in a single transaction.

  @doc """
  Delete a workspace AND every piece of state it owns, atomically.

  Ordered cleanup in a single `Repo.transaction`:

    0. Sweep the 4 E3/allowlist string-keyed tables the keystone exporter
       copies (charter D4/D5) — the FK-less `(doc_id, dataset)`-keyed tables
       (`authoring_exemptions`, `github_sync_conflicts`) and bare-dataset-keyed
       tables (`preview_token_jti`, `shares`) the SQL cascade never reaches. The
       `scope`-column allowlist is EMPTY: both `data_keys` /
       `search_surface_config` AND the five `sync_*` tables are E1 after their
       per-workspace attribution (charter D45/D49, D51-D54, D55) — the step-3 FK
       cascade sweeps them, touching ONLY this workspace's own rows (its DEKs,
       cursors, dead-letters and push-ledger). Runs FIRST because its
       `(doc_id, dataset)`
       semi-join needs the workspace's own `documents` still present and its
       slug derivation needs its projects/datasets still present. A
       `(doc_id, dataset)` row ALSO owned by a sibling workspace is guarded and
       SURVIVES. Reuses the keystone enumeration + slug derivation, so export
       and teardown share ONE source of truth for a workspace's tables.
    1. For every media_file scoped to the workspace, call
       `Barkpark.Media.delete_file/2` so the disk blob is removed
       (`File.rm`), CDN edge cache is invalidated (`Cdn.invalidate`),
       renditions are deleted (`Renditions.delete_for_file`), and the
       `after_media_delete` plugin hook fires.
    2. For every document scoped to the workspace, call
       `Barkpark.Content.delete_document/4` so the `:after_delete`
       lifecycle hook fires for every doc.
    3. `Repo.delete(workspace)` — the workspace row leaves. The SQL
       cascade chain (workspace → projects → datasets, and the scope-FK
       cascades on documents/revisions/media_files/schema_definitions/
       webhooks/mutation_events/search_intel_events/
       search_intel_crystals/search_intel_merge_patterns/search_synonyms/
       paper_events) sweeps any rows that survived the app-level pass
       (idempotent) and removes the supporting rows that have no
       side-effect cleanup.

  ## The two FK-less audit tables (charter D4/D5, `bl-audit-fk-orphans`)

  `audit_events` and `audit_export_sinks` carry `workspace_id` as a plain
  `binary_id` with ZERO foreign key (migrations `20260705120000` /
  `20260705140000`), so the SQL cascade in step 3 never reaches them. They get
  DIFFERENT, deliberate treatment — one swept, one retained:

    * `audit_export_sinks` (step 2b) — SWEPT. A plain mutable config table
      (no trigger, no FK) holding SIEM/webhook endpoint URLs + secrets. It has
      no forensic value and its secrets must not outlive the workspace, so an
      explicit workspace-scoped `Repo.delete_all` removes it.
    * `audit_events` — RETAINED BY DESIGN, never touched here. It is the
      tamper-evident, append-only, per-workspace sha256 hash chain, protected
      by a DB-level `BEFORE UPDATE OR DELETE` trigger
      (`audit_events_no_update_delete`) that RAISES on any delete. Carving a
      teardown exception into that trigger would defeat the exact guarantee the
      chain exists to provide (a compromised delete path could then erase
      history). Retaining a deleted workspace's audit trail is the correct
      compliance/forensics posture, so we intentionally leave those rows in
      place — orphaned of their workspace row, but by decision, not by neglect.

  The whole sequence runs inside a single `Repo.transaction`. If ANY step
  fails — a hook returns an error, a Repo write blows up, the workspace
  delete races — the transaction rolls back and nothing partial-deletes.

  Media-delete side effects are ATOMIC with the transaction: while inside it,
  `Media.delete_file/2` DEFERS its four irreversible non-DB effects (on-disk
  `File.rm`, CDN purge, the `media.deleted` webhook, rendition removal) into a
  process-dict queue instead of firing them eagerly. This function FLUSHES that
  queue only on `{:ok, _}` (commit) and DROPS it on rollback/rescue — so an
  aborted teardown leaves each surviving `media_file` row's blob, CDN entry, and
  renditions intact (no phantom media). The single in-transaction DB write those
  deletes still make — the `:after_media_delete` plugin hook — rolls back with
  the rest (its contract is DB-writes-only; see `Media.delete_file/2`).

  Accepts a `%Workspace{}` struct or a workspace id binary. Returns
  `{:ok, workspace}` on success or `{:error, term}` on rollback.
  Looking up an unknown id returns `{:error, :not_found}` without opening
  a transaction.
  """
  @spec delete_workspace(Workspace.t() | binary()) ::
          {:ok, Workspace.t()} | {:error, :not_found | term()}
  def delete_workspace(%Workspace{} = workspace) do
    # Media-delete effects (File.rm / CDN purge / media.deleted webhook /
    # rendition removal) fired by `Media.delete_file/2` inside the transaction
    # below are DEFERRED (it detects `Repo.in_transaction?/0`) so a mid-delete
    # rollback — e.g. a halted document delete — cannot strand a surviving
    # media_file row's blob. Clear any stale queue, then FLUSH on commit /
    # DROP on rollback. Mirrors Content.Mutations.apply_mutations' broadcast
    # triad.
    Media.clear_deferred_media_effects()

    result =
      Repo.transaction(fn ->
        case do_delete_workspace(workspace) do
          {:ok, ws} -> ws
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, _} -> Media.flush_deferred_media_effects()
      _ -> Media.clear_deferred_media_effects()
    end

    result
  rescue
    e ->
      Media.clear_deferred_media_effects()
      reraise(e, __STACKTRACE__)
  end

  def delete_workspace(id) when is_binary(id) do
    case get_workspace_by_id(id) do
      nil -> {:error, :not_found}
      %Workspace{} = workspace -> delete_workspace(workspace)
    end
  end

  # Ordered cleanup inside the transaction. Each step short-circuits on
  # error so the transaction rolls back via Repo.rollback in the wrapper.
  defp do_delete_workspace(%Workspace{id: ws_id} = workspace) do
    with :ok <- delete_workspace_string_keyed(workspace),
         :ok <- delete_workspace_media(ws_id),
         :ok <- prepare_workspace_cycle_teardown(ws_id),
         :ok <- delete_workspace_documents(ws_id),
         :ok <- delete_workspace_audit_sinks(ws_id),
         {:ok, _} <- Repo.delete(workspace) do
      {:ok, workspace}
    else
      {:error, _} = err -> err
    end
  end

  defp prepare_workspace_cycle_teardown(ws_id) do
    Repo.query!("SELECT barkpark_prepare_workspace_cycle_teardown($1)", [Ecto.UUID.dump!(ws_id)])
    :ok
  end

  # Sweep the 4 E3 string-keyed tables the keystone exporter copies
  # (charter D4/D5): the 2 E3 doc-keyed (Catalog.e3_doc_keyed/0) and the 2 E3
  # dataset-keyed (Catalog.e3_dataset_keyed/0). The scope-column allowlist
  # (Catalog.allowlist/0) is now EMPTY, so its sweep loop below is a no-op over
  # zero tables. NONE of the swept tables carries `workspace_id` — their tenant
  # key is a `(doc_id, dataset)` leaf or a `scope` string — so the SQL CASCADE on
  # `Repo.delete(workspace)` NEVER reaches them; without this explicit step a
  # torn-down workspace silently orphans (e.g.) its authoring_exemptions ledger.
  # Both former allowlist members left this sweep once they gained a
  # `workspace_id` FK and moved to E1, cascade-deleting with the workspace in
  # step 3 (which touches ONLY this workspace's own rows):
  #   * `search_surface_config` — Wave 5 Slice A (charter D45/D49).
  #   * `data_keys` — the per-dataset DEK store; a sibling's shared-slug DEK now
  #     survives via the FK cascade instead of a bare-scope delete
  #     (bpb-datakeys-write-path-workspace-attribution, charter D51-D54).
  #
  # The five `sync_*` tables are NOT here: per-workspace attribution (charter
  # D55) gave them a `workspace_id` FK, so they are E1 now and the SQL CASCADE on
  # `Repo.delete(workspace)` sweeps them like any other E1 table.
  #
  # POSITION IS LOAD-BEARING — this runs FIRST, before media/documents/audit and
  # before the final cascade: the E3 doc-keyed semi-join needs the workspace's
  # OWN `documents` rows still present, and the dataset-slug derivation
  # (`WorkspaceBundle.dataset_slugs_for/1`) needs its projects+datasets still
  # present — both leave only at `Repo.delete(workspace)`.
  #
  # The predicate shapes are the EXACT keystone extraction shapes
  # (`WorkspaceBundle.copy_where/4`), so export and teardown agree on membership:
  #   * E3 doc-keyed — a `(doc_id, dataset)` semi-join (EXISTS, never a JOIN,
  #     which would fan out on the 2-document case — charter D6), PLUS a
  #     sibling-guard `NOT EXISTS` so a `(doc_id, dataset)` row ALSO owned by a
  #     DIFFERENT workspace (charter D7 — the key is not workspace-unique)
  #     SURVIVES this workspace's teardown.
  #   * E3 dataset-keyed — SPLIT PER TABLE, exactly as the exporter splits it
  #     (PDS-D74), off the one shared map
  #     `Catalog.e3_dataset_workspace_slug_column/0`:
  #       - a table with its OWN workspace slug column is swept by THAT column
  #         (`workspaces.slug` is uniquely indexed, so it names one tenant), which
  #         is the only shape that reaches its rows under a SHARED dataset slug —
  #         the same rows the export now carries;
  #       - a table without one keeps `t.dataset = ANY(slugs)` over the
  #         PROJECT-QUALIFIED (workspace-EXCLUSIVE) set from
  #         `WorkspaceBundle.dataset_slugs_for/1`: a slug shared with another
  #         workspace is dropped, so this bare-slug sweep can never cross-tenant
  #         delete a co-tenant's rows under the same slug (charter D21). Its
  #         shared-slug rows are LEFT, and the export declares them as loss.
  #   * allowlist — `t.scope = ANY(prefix <> slug)` with the per-table prefix.
  #     The allowlist is EMPTY as of Wave 5 (both `search_surface_config` and
  #     `data_keys` gained a `workspace_id` FK and moved to E1), so this loop
  #     currently matches no table; the shape is retained for any future
  #     bare-`scope` tenant table.
  defp delete_workspace_string_keyed(%Workspace{id: ws_id, slug: ws_slug}) do
    ws_lit = Catalog.uuid_literal!(ws_id)
    slugs = WorkspaceBundle.dataset_slugs_for(ws_id)

    Enum.each(Catalog.e3_doc_keyed(), &delete_e3_doc_keyed(&1, ws_lit))
    Enum.each(Catalog.e3_dataset_keyed(), &delete_e3_dataset_keyed(&1, ws_slug, slugs))

    for {table, prefix} <- Catalog.allowlist() do
      delete_allowlist_scoped(table, prefix, slugs)
    end

    :ok
  end

  # E3 doc-keyed sweep: mirrors `WorkspaceBundle.copy_where(_, :e3_doc, …)`
  # verbatim (the `(doc_id, dataset)` EXISTS semi-join) + the sibling-guard.
  # Reachability: both interpolands are closed — `table` comes from
  # `Catalog.e3_doc_keyed/0` (a pinned literal map) via `qi/1`, `ws_lit` from
  # `Catalog.uuid_literal!/1`, which raises on anything that is not a UUID.
  # sobelow_skip ["SQL.Query"]
  defp delete_e3_doc_keyed(table, ws_lit) do
    Repo.query!(
      "DELETE FROM #{qi(table)} t " <>
        "WHERE EXISTS (SELECT 1 FROM documents d " <>
        "WHERE d.workspace_id = #{ws_lit} AND d.doc_id = t.doc_id AND d.dataset = t.dataset) " <>
        "AND NOT EXISTS (SELECT 1 FROM documents d2 " <>
        "WHERE d2.doc_id = t.doc_id AND d2.dataset = t.dataset AND d2.workspace_id <> #{ws_lit})",
      []
    )
  end

  # E3 dataset-keyed sweep: mirrors `WorkspaceBundle.copy_where(_, :e3_dataset, …)`
  # — INCLUDING its split (PDS-D74), which is the whole reason both sides read the
  # same `Catalog.e3_dataset_workspace_slug_column/0` map. Splitting the export
  # without splitting this sweep is not a cosmetic mismatch: the exporter would
  # claim a shared-slug `shares` row as this workspace's while the teardown left
  # it behind, so a workspace that was backed up and then deleted would strand
  # rows its own bundle said it owned. That desync passed 98 tests, which is why
  # the binding assertion lives in workspace_bundle_test.exs and not in a comment.
  #
  # Reachability: `table` and `col` are pinned `Catalog` literals via `qi/1`;
  # `ws_slug` and `slugs` are rendered by `Catalog.text_literal/1` /
  # `text_array_literal/1`, which single-quote and double every embedded quote.
  # sobelow_skip ["SQL.Query"]
  defp delete_e3_dataset_keyed(table, ws_slug, slugs) do
    where =
      case Map.fetch(Catalog.e3_dataset_workspace_slug_column(), table) do
        # Safe precisely because `workspaces.slug` is uniquely indexed, so this
        # names ONE tenant — and it sweeps the shared-slug rows the bare
        # predicate below cannot touch, exactly the ones the export now carries.
        {:ok, col} ->
          "t.#{qi(col)} = #{Catalog.text_literal(ws_slug)}"

        # The bare, workspace-EXCLUSIVE slug set. An empty set yields
        # `ANY(ARRAY[]::text[])`, which matches nothing — fail-closed: a row
        # under a shared slug is LEFT (an orphan is recoverable; a cross-tenant
        # delete is not). The export declares that same population as loss.
        :error ->
          "t.dataset = ANY(#{Catalog.text_array_literal(slugs)})"
      end

    Repo.query!("DELETE FROM #{qi(table)} t WHERE #{where}", [])
  end

  # allowlist sweep: mirrors `WorkspaceBundle.copy_where(_, :allowlist, …)` —
  # the `scope`-column tables prefixed per `Catalog.allowlist/0`.
  # Reachability: DEAD as of Wave 5 — `Catalog.allowlist/0` is `%{}`, so the
  # only call site's `for` comprehension never iterates; if it is ever revived,
  # the interpolands are a pinned table name and a `text_array_literal/1` array.
  # sobelow_skip ["SQL.Query"]
  defp delete_allowlist_scoped(table, prefix, slugs) do
    scopes = Enum.map(slugs, &(prefix <> &1))

    Repo.query!(
      "DELETE FROM #{qi(table)} t WHERE t.scope = ANY(#{Catalog.text_array_literal(scopes)})",
      []
    )
  end

  # Double-quote a catalog-derived table name (every value originates from
  # `Catalog`'s pinned constants, never user input; the quote-doubling is
  # belt-and-suspenders, matching `WorkspaceBundle.qi/1`).
  defp qi(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  # Sweep the workspace's audit_export_sinks. This table carries workspace_id as
  # a plain binary_id with NO foreign key (migration 20260705140000), so the SQL
  # CASCADE on `Repo.delete(workspace)` never reaches it — without this explicit
  # step a torn-down workspace would silently orphan its SIEM sink config
  # (endpoint URLs + secrets). It is a plain mutable table (no immutability
  # trigger), so a scoped `delete_all` is safe. Its sibling `audit_events` is
  # intentionally RETAINED (append-only forensic chain; see delete_workspace/1
  # moduledoc for why we do NOT delete audit history on teardown).
  defp delete_workspace_audit_sinks(ws_id) do
    ExportSink
    |> where([s], s.workspace_id == ^ws_id)
    |> Repo.delete_all()

    :ok
  end

  # Walk every media_file scoped to the workspace and route it through
  # `Media.delete_file/2` so File.rm + Cdn.invalidate + Renditions.delete_for_file
  # + Plugins.Registry.run_after_media_delete + Events.dispatch all fire. Without
  # this the SQL CASCADE on media_files (migration 20260527160000) would silently
  # remove the row and leak the blob on disk and at the CDN edge.
  defp delete_workspace_media(ws_id) do
    MediaFile
    |> where([m], m.workspace_id == ^ws_id)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn %MediaFile{} = file, :ok ->
      case Media.delete_file(file.id, workspace_id: ws_id) do
        {:ok, _} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Walk every document scoped to the workspace (BOTH drafts and published
  # rows — list_documents would skip drafts on its default perspective, so
  # we drive a raw query that picks every row up). Each unique `doc_id` is
  # routed through `Content.delete_document/4`, which deletes BOTH variants
  # and fires `:before_delete` / `:after_delete` plugin hooks.
  defp delete_workspace_documents(ws_id) do
    docs =
      Document
      |> where([d], d.workspace_id == ^ws_id)
      |> select([d], {d.doc_id, d.type, d.dataset})
      |> Repo.all()
      |> Enum.map(fn {doc_id, type, dataset} ->
        # `delete_document/4` strips the drafts prefix internally; normalising
        # here lets us dedupe a doc that exists as BOTH a draft and published row.
        {Content.published_id(doc_id), type, dataset}
      end)
      |> Enum.uniq()

    Enum.reduce_while(docs, :ok, fn {base_id, type, dataset}, :ok ->
      case Content.delete_document(base_id, type, dataset, workspace_id: ws_id) do
        {:ok, _} -> {:cont, :ok}
        # `delete_document` returns :not_found when both variants are
        # already gone — a benign race or duplicate `doc_id` row that an
        # earlier iteration handled. Move on.
        {:error, :not_found} -> {:cont, :ok}
        # Halted plugin hook bubbles up so the surrounding transaction
        # rolls back rather than partial-deleting.
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
