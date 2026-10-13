defmodule BarkparkWeb.CodelistController do
  @moduledoc """
  `GET /w/:ws/p/:proj/v1/codelists/:codelist_id` — read a registered
  codelist's values over HTTP (task-93b24f20348f6df0).

  Codelists are registered only from Elixir (`Codelists.register/3`, `mix
  barkpark.codelists.seed`, plugin seeders), keyed `(plugin_name, list_id,
  issue)` with NO workspace scope — the registry is a global reference table,
  not tenant data. This route is mounted on the plain token-required
  scoped-read pipeline purely for AUTHENTICATION parity with the rest of the
  scoped API (any workspace member token, not anonymous); it reads the same
  global registry regardless of which workspace/project the URL names.

  A schema field `{type: "codelist", codelistId: "onixedit:thema"}` stores
  one code string from a list named by `list_id` alone — the convention
  `Codelists` documents is `list_id = "<plugin_name>:<name>"`, with
  `plugin_name` ALSO stored as its own column (redundant, for grep-ability).
  Every call site that registers a list passes that same prefixed string as
  BOTH the id a schema field names AND the second `Codelists.register/get/3`
  arg, so `:codelist_id` here is split on its first `:` to recover the
  `plugin_name` `Codelists.get/2` and `Codelists.tree/3` need, without this
  route's caller ever needing to know a separate plugin argument.

  Returns the codelist as a TREE (`Codelists.tree/3` — root values with
  nested `children`; a flat codelist is simply a tree with no children, so
  one shape covers both the B05 flat picker and the hierarchical one).
  `?lang=nob,eng` picks the label language preference order (same default,
  `["nob", "eng"]`, `Codelists` itself uses); the first query value present
  for a given code wins, exactly like `Codelists.lookup/4`'s own semantics.
  404 when the codelist id resolves to nothing (unknown plugin prefix, or a
  list nobody registered).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content.Codelists
  alias BarkparkWeb.ErrorResponse

  def show(conn, %{"codelist_id" => codelist_id} = params) do
    with {:ok, plugin_name} <- split_plugin(codelist_id),
         %Codelists.Codelist{} = codelist <- Codelists.get(plugin_name, codelist_id) do
      tree_opts =
        case parse_languages(params["lang"]) do
          nil -> []
          languages -> [languages: languages]
        end

      json(conn, %{
        codelistId: codelist_id,
        name: codelist.name,
        description: codelist.description,
        issue: codelist.issue,
        values: Codelists.tree(plugin_name, codelist_id, tree_opts)
      })
    else
      _ ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no codelist registered as #{inspect(codelist_id)}"
        )
    end
  end

  # `list_id`'s own documented convention: "<plugin>:<name>". A caller-supplied
  # id with no colon at all names no plugin to look under — refuse rather
  # than guess, same shape as every other "unresolvable scope" 404 here.
  defp split_plugin(codelist_id) do
    case String.split(codelist_id, ":", parts: 2) do
      [plugin, _name] when plugin != "" -> {:ok, plugin}
      _ -> :error
    end
  end

  defp parse_languages(nil), do: nil

  defp parse_languages(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      langs -> langs
    end
  end

  defp parse_languages(_other), do: nil
end
