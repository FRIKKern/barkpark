defmodule Barkpark.Sharing do
  @moduledoc """
  Scoped-sharing registry — the source of truth for which tenant scopes are
  exposed on the network.

  Declares, in one place, which tenant scopes (workspace / project / dataset)
  expose which surfaces (`:papers`, `:docs`, `:media`) at which access level
  (`:read` or `:edit`). `BarkparkWeb.Plugs.RequireShareScope` consults `shared?/4`
  / `access_for/3` on the share-aware scoped read routes.

  ## Two sources, one live list (P4)

  The live `:shares` list has TWO inputs, merged by `refresh/0`:

    * the STATIC `BARKPARK_SHARES` env config (parsed once in `runtime.exs` into
      `:shares_env`), and
    * the PERSISTENT `shares` table (`StoredShare` rows), which `bp share add/rm`
      and the Studio manage at runtime without a restart.

  `refresh/0` recomputes `:shares = shares_env() ++ list_stored()` and is called
  once post-boot and after every store write. `shares/0` (and therefore the
  per-request `shared?/4`) reads only the in-memory `:shares`, so the hot path
  never touches the DB. The store is purely ADDITIVE: with no rows and no env
  config, `:shares` is `[]` and the whole feature is OFF.

  Two invariants are the whole point of this module and must never regress:

    * **Default-OFF** — with no `:shares` configured, `active?/0` is `false`
      and every `shared?/4` query returns `false`.
    * **Default-DENY** — `shared?/4` returns `true` ONLY when a configured
      `Share` matches the `(workspace, project, dataset)` triple EXACTLY and
      lists the requested surface. Anything else (unknown args, partial match,
      surface not listed, malformed/unset config) is a hard `false`. No call
      ever raises.

  ## Env format

  The `:shares` env value is parsed from a single string of `;`-separated
  entries, each `"<scope>:<surfaces>:<access>"`:

    * `scope` — `"ws"`, `"ws/project"`, or `"ws/project/dataset"`. A missing
      project defaults to `"default"` and a missing dataset to `"production"`
      (the canonical Tenancy slugs).
    * `surfaces` — comma-separated subset of `papers,docs,media`. Unknown
      surface tokens are dropped with a warning; an entry with zero valid
      surfaces is skipped.
    * `access` — `"read"` or `"edit"`, defaulting to `"read"` when the third
      segment is omitted. An unknown access value skips the whole entry.

  Parsing is TOLERANT: any malformed entry is skipped (and logged), never
  crashes, and never accidentally grants access. `runtime.exs` will, in a later
  phase, call `parse/1` and stash the result under `:barkpark, :shares`.
  """

  require Logger

  import Ecto.Query, only: [where: 3]

  alias Barkpark.Repo
  alias Barkpark.Sharing.StoredShare

  # The canonical Tenancy defaults (mirrors Barkpark.Tenancy's
  # @default_project_slug / @production_dataset_slug). Kept as literals here so
  # this module stays free of any Tenancy dependency — it is pure data.
  @default_project "default"
  @default_dataset "production"

  # The ONLY surfaces a share may expose, and the ONLY access levels.
  @surfaces ~w(papers docs media)a
  @accesses ~w(read edit)a

  defmodule Share do
    @moduledoc """
    A single sharing grant: a tenant scope plus the surfaces it exposes and the
    access level it grants. Pure value object — produced by
    `Barkpark.Sharing.parse/1`, never persisted.
    """

    @enforce_keys [:workspace_slug, :project_slug, :dataset, :surfaces, :access]
    defstruct [:workspace_slug, :project_slug, :dataset, :surfaces, :access]

    @type surface :: :papers | :docs | :media
    @type access :: :read | :edit

    @type t :: %__MODULE__{
            workspace_slug: String.t(),
            project_slug: String.t(),
            dataset: String.t(),
            surfaces: [surface()],
            access: access()
          }
  end

  @doc """
  The surfaces a share may legally expose.
  """
  @spec surfaces() :: [Share.surface()]
  def surfaces, do: @surfaces

  @doc """
  The access levels a share may legally grant.
  """
  @spec accesses() :: [Share.access()]
  def accesses, do: @accesses

  @doc """
  Parse the env string into a list of `Share` structs.

  Returns `[]` for `nil` or `""`. Tolerant — any malformed entry is logged and
  skipped, never raising, never granting.
  """
  @spec parse(binary() | nil) :: [Share.t()]
  def parse(nil), do: []

  def parse(binary) when is_binary(binary) do
    binary
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_entry/1)
  end

  def parse(_other), do: []

  @doc """
  The configured shares — the already-parsed list under `:barkpark, :shares`.

  Tolerates the key being unset (→ `[]`). Defensive against a misconfigured
  value: anything that is not a list of `Share` structs collapses to `[]`.
  """
  @spec shares() :: [Share.t()]
  def shares do
    case Application.get_env(:barkpark, :shares, []) do
      list when is_list(list) -> Enum.filter(list, &match?(%Share{}, &1))
      _ -> []
    end
  end

  @doc """
  Whether any shares are configured at all.

  This is the Default-OFF switch: with no `:shares`, returns `false`.
  """
  @spec active?() :: boolean()
  def active?, do: shares() != []

  # ── persistent store + live merge (P4) ─────────────────────────────────

  @doc """
  The STATIC env-config baseline — the `parse/1` of `BARKPARK_SHARES`, stashed
  under `:barkpark, :shares_env` by `runtime.exs`. Defensive: anything that is
  not a list of `Share` structs collapses to `[]`. This is the half of the live
  `:shares` list that the store NEVER overwrites.
  """
  @spec shares_env() :: [Share.t()]
  def shares_env do
    case Application.get_env(:barkpark, :shares_env, []) do
      list when is_list(list) -> Enum.filter(list, &match?(%Share{}, &1))
      _ -> []
    end
  end

  @doc """
  Every PERSISTED share, as validated `Share` structs.

  Each `StoredShare` row is rebuilt through the SAME `parse/1` validation as an
  env share, so a malformed/stale row is silently dropped — the store can never
  widen access beyond what the one parser would grant.
  """
  @spec list_stored() :: [Share.t()]
  def list_stored do
    StoredShare
    |> Repo.all()
    |> Enum.flat_map(&stored_to_shares/1)
  end

  @doc """
  Recompute the live `:shares` list = `shares_env/0` ++ `list_stored/0`.

  Called once post-boot and after every store write. GUARDED: if the store is
  unavailable (e.g. queried before the Repo/sandbox is ready, or the table is
  missing), the live `:shares` is left exactly as it was — boot never crashes
  and the env baseline is never lost. Returns `:ok` either way.
  """
  @spec refresh() :: :ok
  def refresh do
    stored = list_stored()
    Application.put_env(:barkpark, :shares, shares_env() ++ stored)
    :ok
  rescue
    e ->
      Logger.warning("[Sharing] refresh skipped (store unavailable): #{inspect(e)}")
      :ok
  end

  @doc """
  Persist a share from a single env-entry string (`"<scope>:<surfaces>:<access>"`)
  and `refresh/0` the live list.

  The entry is validated through `parse/1` FIRST — exactly one valid `Share`
  must result, or this is a no-op returning `{:error, :invalid}` (a multi-entry
  string, a wildcard scope, an unknown surface-only entry, etc. all fail here).
  A scope that already has a row is UPSERTED (its surfaces/access replaced).
  Returns `{:ok, Share.t()}` on success.
  """
  @spec add_share(binary()) :: {:ok, Share.t()} | {:error, term()}
  def add_share(entry) when is_binary(entry) do
    case parse(entry) do
      [%Share{} = share] ->
        attrs = %{
          workspace_slug: share.workspace_slug,
          project_slug: share.project_slug,
          dataset: share.dataset,
          surfaces: Enum.map(share.surfaces, &Atom.to_string/1),
          access: Atom.to_string(share.access)
        }

        %StoredShare{}
        |> StoredShare.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:surfaces, :access, :updated_at]},
          conflict_target: [:workspace_slug, :project_slug, :dataset]
        )
        |> case do
          {:ok, _row} ->
            refresh()
            {:ok, share}

          {:error, changeset} ->
            {:error, changeset}
        end

      _ ->
        {:error, :invalid}
    end
  end

  def add_share(_other), do: {:error, :invalid}

  @doc """
  Delete the persisted share for the exact `(workspace, project, dataset)` triple
  and `refresh/0` the live list. Returns `{:ok, count_deleted}` (0 if none).

  This only removes STORED shares — a share declared via `BARKPARK_SHARES`
  (the env baseline) is not in the table and is unaffected.

  THE KILL SWITCH KILLS THREE THINGS, and the returned count names only the
  first. Beyond deleting the row it hard-revokes, unconditionally and whether or
  not a row was there to delete:

    * every live scoped-share EDIT TOKEN under the scope
      (`Barkpark.Auth.revoke_share_tokens/3`), and
    * every live ITEM SHARE LINK under the scope
      (`Barkpark.Sharing.Links.revoke_scope/3`) — the `/s/<token>` URLs, which
      are stable and re-copyable and may already be pasted somewhere.

  The item-link cascade is RULED behaviour (lead-security-r, 2026-09-02), not an
  accident: an operator who removes a share believes access is withdrawn, and
  item links derive their authority from the share they were minted under, so
  they fall with it. Before it, `/s/<token>` kept serving after the share was
  gone — a leak the operator could not see. Sibling scopes are untouched: the
  cascade matches the `(workspace, project, dataset)` triple exactly.
  """
  @spec remove_share(binary(), binary(), binary()) :: {:ok, non_neg_integer()}
  def remove_share(ws_slug, proj_slug, dataset)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    {count, _} =
      StoredShare
      |> where(
        [s],
        s.workspace_slug == ^ws_slug and s.project_slug == ^proj_slug and s.dataset == ^dataset
      )
      |> Repo.delete_all()

    # P5 belt-and-suspenders: removing a share hard-revokes any edit tokens bound
    # to this scope. (Downgrading :edit→:read already makes them inert live, via
    # RequireShareEditToken's access_for re-check; this also kills them on full
    # removal so a re-added :read share can never resurrect a stale edit token.)
    Barkpark.Auth.revoke_share_tokens(ws_slug, proj_slug, dataset)

    # THE CASCADE (arpss-w8, RULED CASCADE): the same removal kills the ITEM
    # `/s/<token>` links minted under this scope. Unconditional, exactly like
    # the token revoke above and for the same reason — a share can be removed
    # with `count == 0` (an env-baseline or already-deleted row) while live
    # links still hang off the scope, so gating the cascade on `count` would
    # reintroduce the hole on the path that most looks like a no-op.
    Barkpark.Sharing.Links.revoke_scope(ws_slug, proj_slug, dataset)

    refresh()
    {:ok, count}
  end

  @doc """
  Split a scope string into the canonical `{ws, project, dataset}` triple,
  applying the default project (`"default"`) and dataset (`"production"`) — the
  SAME rules `parse/1` uses. Returns `{:error, reason}` for a malformed or
  wildcard scope. Used by the `/v1/shares` delete path.
  """
  @spec scope_triple(term()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  def scope_triple(scope) when is_binary(scope), do: parse_scope(scope)
  def scope_triple(_other), do: {:error, "invalid scope"}

  @spec stored_to_shares(StoredShare.t()) :: [Share.t()]
  defp stored_to_shares(%StoredShare{} = s) do
    surfaces = s.surfaces |> List.wrap() |> Enum.join(",")

    "#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}:#{surfaces}:#{s.access}"
    |> parse()
  end

  @doc """
  STRICT DEFAULT-DENY surface check.

  Returns `true` ONLY when a configured `Share` matches the
  `(workspace, project, dataset)` triple EXACTLY and lists `surface`. The
  surface may be given as an atom (`:papers`) or a string (`"papers"`); unknown
  surfaces, unknown args, no match, or unset config all yield `false`. Never
  raises.
  """
  @spec shared?(term(), term(), term(), Share.surface() | String.t()) :: boolean()
  def shared?(ws_slug, proj_slug, dataset, surface)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    case normalize_surface(surface) do
      nil ->
        false

      surf ->
        Enum.any?(shares(), fn %Share{} = s ->
          s.workspace_slug == ws_slug and
            s.project_slug == proj_slug and
            s.dataset == dataset and
            surf in s.surfaces
        end)
    end
  end

  def shared?(_ws_slug, _proj_slug, _dataset, _surface), do: false

  @doc """
  The access level granted to the `(workspace, project, dataset)` triple, or
  `nil` if no `Share` matches.

  When more than one matching share exists, `:edit` wins over `:read` (the
  broader grant). Never raises.
  """
  @spec access_for(term(), term(), term()) :: Share.access() | nil
  def access_for(ws_slug, proj_slug, dataset)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    shares()
    |> Enum.filter(fn %Share{} = s ->
      s.workspace_slug == ws_slug and
        s.project_slug == proj_slug and
        s.dataset == dataset
    end)
    |> Enum.map(& &1.access)
    |> Enum.reduce(nil, fn
      :edit, _acc -> :edit
      :read, :edit -> :edit
      :read, _acc -> :read
    end)
  end

  def access_for(_ws_slug, _proj_slug, _dataset), do: nil

  # ── LAN discovery + reader URLs (P1c) ──────────────────────────────────

  @doc """
  The machine's primary LAN IPv4 address, as a binary like `"10.0.0.5"`, or
  `nil` when none can be determined.

  Reads the system via `:inet.getifaddrs/0`, skipping the loopback interface
  (`127.0.0.0/8`). The first non-loopback IPv4 address wins. Never raises —
  any error from the OS collapses to `nil`.

  This is the ONLY function here that touches the system; everything else is
  pure. It exists so the boot banner can print a copy-pasteable reader URL.
  """
  @spec lan_ip() :: binary() | nil
  def lan_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_ifname, opts} ->
          for {:addr, {a, _, _, _} = ip} <- opts, a != 127, do: ip
        end)
        |> List.first()
        |> ip_to_binary()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @spec ip_to_binary({integer(), integer(), integer(), integer()} | nil) :: binary() | nil
  defp ip_to_binary(nil), do: nil

  defp ip_to_binary({_, _, _, _} = ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  @doc """
  Reader base URLs for every configured `:papers` share, using the detected
  LAN IP and the configured HTTP port.

  Returns a list of `{share, url}` tuples (one per `:papers` share). When the
  LAN IP can't be determined, returns `[]`. Shares that do NOT expose `:papers`
  contribute no URL. With no shares (Default-OFF) this is `[]`.

  See `share_urls/2` for the pure derivation given an explicit `ip` + `port`.
  """
  @spec share_urls() :: [{Share.t(), binary()}]
  def share_urls do
    case lan_ip() do
      nil -> []
      ip -> share_urls(ip, http_port())
    end
  end

  @doc """
  PURE derivation of `:papers` reader base URLs from the configured shares,
  given an explicit `ip` and `port`.

  For each share that lists the `:papers` surface, builds
  `http://<ip>:<port>/w/<ws>/p/<proj>/papers/`. Shares without `:papers`
  yield nothing. Returns a list of `{share, url}` tuples, in `shares/0` order.
  """
  @spec share_urls(binary(), integer()) :: [{Share.t(), binary()}]
  def share_urls(ip, port) when is_binary(ip) and is_integer(port) do
    for %Share{surfaces: surfaces} = s <- shares(), :papers in surfaces do
      url =
        "http://#{ip}:#{port}/w/#{s.workspace_slug}/p/#{s.project_slug}/papers/"

      {s, url}
    end
  end

  @doc """
  The base URL a SHARE LINK should advertise so it works for someone ELSE — a
  configured public host (the Endpoint `:url` host, e.g. a domain in prod) when
  one is set, else the detected LAN IPv4 (`http://<ip>:<port>`), else `nil`.

  This is what a Studio share link uses instead of `localhost` (which only
  resolves on the host machine). The caller appends `/s/<token>`.
  """
  @spec share_link_base() :: binary() | nil
  def share_link_base do
    configured_share_host() || configured_public_base() || lan_base_url()
  end

  # An explicit operator override (BARKPARK_SHARE_HOST, set in runtime.exs) — the
  # public host share links should advertise, e.g. a tunnel domain
  # (https://abc.trycloudflare.com) so a link reaches someone OUTSIDE the LAN
  # with the firewall untouched. Accepts a bare host or a full URL; defaults the
  # scheme to https and strips a trailing slash. Wins over the LAN IP / Endpoint
  # url so the operator can point share links anywhere reachable.
  @spec configured_share_host() :: binary() | nil
  defp configured_share_host do
    case Application.get_env(:barkpark, :share_host) do
      host when is_binary(host) and host != "" ->
        host = String.trim_trailing(host, "/")
        if String.match?(host, ~r{^https?://}i), do: host, else: "https://#{host}"

      _ ->
        nil
    end
  end

  @doc """
  `http://<lan-ipv4>:<port>` for the machine, or `nil` when no LAN IPv4 is
  detectable. The LAN fallback for `share_link_base/0`.
  """
  @spec lan_base_url() :: binary() | nil
  def lan_base_url do
    case lan_ip() do
      nil -> nil
      ip -> "http://#{ip}:#{http_port()}"
    end
  end

  # The Endpoint's configured public URL when its host is a REAL host (not a
  # loopback/wildcard) — that is the right share base in production (a domain),
  # where the LAN IP would be wrong. Returns nil in dev (host "localhost") so the
  # LAN IP is used instead.
  @spec configured_public_base() :: binary() | nil
  defp configured_public_base do
    url = :barkpark |> Application.get_env(BarkparkWeb.Endpoint, []) |> Keyword.get(:url, [])
    host = Keyword.get(url, :host)

    if is_binary(host) and host not in ~w(localhost 127.0.0.1 0.0.0.0) do
      scheme = to_string(Keyword.get(url, :scheme, "http"))
      port = Keyword.get(url, :port)
      suffix = if port in [nil, 80, 443], do: "", else: ":#{port}"
      "#{scheme}://#{host}#{suffix}"
    end
  end

  # The configured HTTP port for the endpoint, defaulting to 4000. Reads the
  # already-merged Endpoint config (runtime.exs sets `http: [port: …]`).
  @spec http_port() :: integer()
  defp http_port do
    :barkpark
    |> Application.get_env(BarkparkWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4000)
    |> case do
      port when is_integer(port) -> port
      _ -> 4000
    end
  end

  # ── parsing internals ─────────────────────────────────────────────────

  @spec parse_entry(String.t()) :: [Share.t()]
  defp parse_entry(entry) do
    case String.split(entry, ":") do
      [scope, surfaces] ->
        build_share(entry, scope, surfaces, "read")

      [scope, surfaces, access] ->
        build_share(entry, scope, surfaces, access)

      _ ->
        Logger.warning("[Sharing] skipping malformed share entry: #{inspect(entry)}")
        []
    end
  end

  @spec build_share(String.t(), String.t(), String.t(), String.t()) :: [Share.t()]
  defp build_share(entry, scope, surfaces_raw, access_raw) do
    with {:ok, {ws, proj, dataset}} <- parse_scope(scope),
         {:ok, access} <- parse_access(access_raw),
         surfaces when surfaces != [] <- parse_surfaces(surfaces_raw) do
      [
        %Share{
          workspace_slug: ws,
          project_slug: proj,
          dataset: dataset,
          surfaces: surfaces,
          access: access
        }
      ]
    else
      [] ->
        Logger.warning("[Sharing] skipping share entry with no valid surfaces: #{inspect(entry)}")
        []

      {:error, reason} ->
        Logger.warning("[Sharing] skipping share entry (#{reason}): #{inspect(entry)}")
        []
    end
  end

  @spec parse_scope(String.t()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  defp parse_scope(scope) do
    segs = scope |> String.split("/") |> Enum.map(&String.trim/1)

    cond do
      # Defense in depth: a scope segment must be non-empty and contain no glob
      # metacharacter. Matching elsewhere is byte-exact (no wildcard expansion),
      # so a literal "*" is inert today — but rejecting it here keeps shares
      # explicit and removes a future wildcard-matching footgun.
      Enum.any?(segs, &(&1 == "" or String.contains?(&1, ["*", "?"]))) ->
        {:error, "invalid scope segment"}

      true ->
        case segs do
          [ws] -> {:ok, {ws, @default_project, @default_dataset}}
          [ws, proj] -> {:ok, {ws, proj, @default_dataset}}
          [ws, proj, dataset] -> {:ok, {ws, proj, dataset}}
          _ -> {:error, "invalid scope"}
        end
    end
  end

  @spec parse_access(String.t()) :: {:ok, Share.access()} | {:error, String.t()}
  defp parse_access(access_raw) do
    case access_raw |> String.trim() |> to_access() do
      nil -> {:error, "unknown access"}
      access -> {:ok, access}
    end
  end

  @spec parse_surfaces(String.t()) :: [Share.surface()]
  defp parse_surfaces(surfaces_raw) do
    surfaces_raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn token ->
      case to_surface(token) do
        nil ->
          Logger.warning("[Sharing] dropping unknown surface token: #{inspect(token)}")
          []

        surf ->
          [surf]
      end
    end)
    |> Enum.uniq()
  end

  @spec normalize_surface(term()) :: Share.surface() | nil
  defp normalize_surface(surface) when is_atom(surface) do
    if surface in @surfaces, do: surface, else: nil
  end

  defp normalize_surface(surface) when is_binary(surface), do: to_surface(surface)
  defp normalize_surface(_), do: nil

  @spec to_surface(String.t()) :: Share.surface() | nil
  defp to_surface(token) do
    Enum.find(@surfaces, fn s -> Atom.to_string(s) == token end)
  end

  @spec to_access(String.t()) :: Share.access() | nil
  defp to_access(token) do
    Enum.find(@accesses, fn a -> Atom.to_string(a) == token end)
  end
end
