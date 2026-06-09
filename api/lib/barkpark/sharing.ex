defmodule Barkpark.Sharing do
  @moduledoc """
  Scoped-sharing registry — the PURE + INERT P1a foundation.

  Declares, in one place, which tenant scopes (workspace / project / dataset)
  expose which surfaces (`:papers`, `:docs`, `:media`) at which access level
  (`:read` or `:edit`). Nothing in the app calls this yet: there is no plug, no
  route, no transport. This module is just a value-object + parser + lookup
  table.

  Two invariants are the whole point of this phase and must never regress:

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
