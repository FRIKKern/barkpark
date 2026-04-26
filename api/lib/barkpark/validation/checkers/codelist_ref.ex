defmodule Barkpark.Validation.Checkers.CodelistRef do
  @moduledoc """
  Checker: a value is a valid code in a codelist pinned to a specific issue.

  Wires Phase 0's codelist registry (`Barkpark.Content.Codelists`) into
  Phase 3's rule DSL. The canonical example is ONIX ContributorRole — list
  17 issue 73 — which surfaces in the OnixEdit plugin from Phase 4 onward.

  ## Params

      %{
        registry_id: "editeur",       # plugin discriminator (Phase 0 plugin_name)
        list_id: "17",                # codelist identifier within the registry
        issue: 73                     # pinned issue/version (string or integer)
      }

  ## Returns

    * `:ok` — value found in the codelist at the requested issue
    * `{:error, :codelist_version_mismatch}` — codelist exists for
      `(registry_id, list_id)` but at a different issue
    * `{:error, :codelist_unknown_value}` — codelist exists at the requested
      issue but does not contain the value, OR the codelist was never
      registered for `(registry_id, list_id)`

  Empty/`nil` values bypass the check (treated as `:ok`); use a separate
  `:required` rule when presence is mandatory.
  """

  @behaviour Barkpark.Validation.Checker

  import Ecto.Query

  alias Barkpark.Content.Codelists.{Codelist, Value}
  alias Barkpark.Repo

  @impl true
  def check(value, params)

  def check(nil, _params), do: :ok
  def check("", _params), do: :ok

  def check(value, %{registry_id: registry_id, list_id: list_id, issue: issue})
      when is_binary(registry_id) and is_binary(list_id) do
    issue_str = to_issue_string(issue)
    code_str = to_code_string(value)

    case fetch_codelist(registry_id, list_id, issue_str) do
      {:ok, codelist} ->
        if value_present?(codelist.id, code_str),
          do: :ok,
          else: {:error, :codelist_unknown_value}

      :version_mismatch ->
        {:error, :codelist_version_mismatch}

      :unknown ->
        {:error, :codelist_unknown_value}
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp to_issue_string(issue) when is_binary(issue), do: issue
  defp to_issue_string(issue) when is_integer(issue), do: Integer.to_string(issue)

  defp to_code_string(value) when is_binary(value), do: value
  defp to_code_string(value) when is_integer(value), do: Integer.to_string(value)
  defp to_code_string(value) when is_atom(value), do: Atom.to_string(value)
  defp to_code_string(value), do: to_string(value)

  defp fetch_codelist(plugin_name, list_id, issue) do
    exact =
      Repo.get_by(Codelist,
        plugin_name: plugin_name,
        list_id: list_id,
        issue: issue
      )

    case exact do
      %Codelist{} = c ->
        {:ok, c}

      nil ->
        if any_issue_for?(plugin_name, list_id),
          do: :version_mismatch,
          else: :unknown
    end
  end

  defp any_issue_for?(plugin_name, list_id) do
    Repo.exists?(
      from c in Codelist,
        where: c.plugin_name == ^plugin_name and c.list_id == ^list_id
    )
  end

  defp value_present?(codelist_id, code) do
    Repo.exists?(
      from v in Value,
        where: v.codelist_id == ^codelist_id and v.code == ^code
    )
  end
end
