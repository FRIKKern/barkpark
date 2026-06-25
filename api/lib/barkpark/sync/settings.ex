defmodule Barkpark.Sync.Settings do
  @moduledoc """
  Resolved configuration for the one-way PULL sync subsystem
  (`Barkpark.Sync`).

  Single source of truth, read from `Application.get_env(:barkpark,
  Barkpark.Sync)` — which `config/runtime.exs` populates from the
  `BARKPARK_SYNC_*` OS env vars at boot (env wins; `config/config.exs` carries
  the dormant `enabled: false` default so a fresh install boots with sync OFF).

  Mirrors the Indx/Bokbasen typed-settings-wrapper precedent
  (`Barkpark.Plugins.Indx.Settings`).

  Fields:

    * `:url`       — base URL of the REMOTE Barkpark to pull from (the
      `GET /v1/data/listen/:dataset` SSE endpoint is appended by the Worker).
    * `:token`     — bearer token for the remote API.
    * `:workspace` — slug of the LOCAL workspace incoming docs are written into.
    * `:dataset`   — dataset string to listen on (remote) and write into (local).
    * `:source`    — derived stable identifier `"<url>#<dataset>"` used as the
      cursor key so two sources targeting the same dataset don't clobber each
      other's high-water mark.
    * `:enabled`   — true ONLY when url+token+dataset+workspace are all present
      AND the configured `enabled` flag is not false. Workspace is required so
      sync always has a resolvable local write target (never a NULL/global
      write — the tenancy invariant). Drives whether the Worker is spliced into
      the supervision tree.
  """

  @enforce_keys []
  defstruct url: nil, token: nil, workspace: nil, dataset: nil, source: nil, enabled: false

  @type t :: %__MODULE__{
          url: String.t() | nil,
          token: String.t() | nil,
          workspace: String.t() | nil,
          dataset: String.t() | nil,
          source: String.t() | nil,
          enabled: boolean()
        }

  @app :barkpark
  @key Barkpark.Sync

  @doc """
  Resolve the sync settings from Application env. Never raises; absent/blank
  keys resolve to `nil` and `enabled: false` (dormant).
  """
  @spec load() :: t()
  def load do
    env = Application.get_env(@app, @key, [])

    url = clean(env[:url])
    token = clean(env[:token])
    workspace = clean(env[:workspace])
    dataset = clean(env[:dataset])
    enabled_flag = Keyword.get(env, :enabled, false)

    creds? = present?(url) and present?(token) and present?(dataset) and present?(workspace)

    %__MODULE__{
      url: url,
      token: token,
      workspace: workspace,
      dataset: dataset,
      source: source_id(url, dataset),
      enabled: creds? and enabled_flag != false
    }
  end

  defp source_id(url, dataset) when is_binary(url) and is_binary(dataset), do: "#{url}##{dataset}"
  defp source_id(_, _), do: nil

  defp clean(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(_), do: nil

  defp present?(v), do: is_binary(v) and v != ""
end
