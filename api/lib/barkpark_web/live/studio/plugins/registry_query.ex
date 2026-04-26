defmodule BarkparkWeb.Studio.Plugins.RegistryQuery do
  @moduledoc """
  Thin wrapper around the Phase 0 codelist registry (`Barkpark.Content.Codelists`)
  for the Phase 4 Studio plugin adapter.

  Exists so the adapter never imports the registry directly: tests can stub the
  loader, missing-module conditions degrade gracefully, and the wrapper can grow
  EDItEUR-aware shortcuts later (Phase 5) without touching every component.

  No EDItEUR-specific code is hard-wired here (decision: WI3 owns
  `Barkpark.Codelists.EDItEUR` — this module must work even when that module is
  not yet pushed).

  ## Plugin discrimination

  Codelist IDs follow the convention `"<plugin>:<list>"` (per
  `Barkpark.Content.Codelists` moduledoc). When a `field.codelist_id` carries a
  `:`, the prefix is the plugin and the suffix is the list_id. When it does
  not, `default_plugin` (passed by the adapter) is used.
  """

  @default_languages ["nob", "eng"]

  @doc """
  Split a `codelist_id` like `"onixedit:contributor_role"` into
  `{plugin, list_id}`. Returns `{default_plugin, codelist_id}` when no `:` is
  present.
  """
  @spec split_codelist_id(String.t() | nil, String.t()) :: {String.t(), String.t()}
  def split_codelist_id(nil, default_plugin), do: {default_plugin, ""}

  def split_codelist_id(id, default_plugin) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [plugin, list_id] when plugin != "" and list_id != "" -> {plugin, list_id}
      _ -> {default_plugin, id}
    end
  end

  @doc """
  Fetch the latest codelist with values + translations preloaded. Returns
  `nil` when nothing is registered, when the registry module is not loaded,
  or when the registry raises (defensive; never bubbles).
  """
  @spec get(String.t(), String.t()) :: map() | nil
  def get(plugin, list_id) when is_binary(plugin) and is_binary(list_id) do
    if Code.ensure_loaded?(Barkpark.Content.Codelists) do
      try do
        apply(Barkpark.Content.Codelists, :get, [plugin, list_id])
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  def get(_, _), do: nil

  @doc """
  Resolve a single code's label. Returns `nil` if registry, codelist, or code
  is missing.
  """
  @spec lookup(String.t(), String.t(), String.t(), keyword()) :: map() | nil
  def lookup(plugin, list_id, code, opts \\ []) do
    languages = Keyword.get(opts, :languages, @default_languages)

    if Code.ensure_loaded?(Barkpark.Content.Codelists) do
      try do
        apply(Barkpark.Content.Codelists, :lookup, [plugin, list_id, code, [languages: languages]])
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  @doc "Default language fallback chain used for label resolution."
  def default_languages, do: @default_languages
end
