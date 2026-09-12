defmodule Barkpark.Content.CodelistHealth do
  @moduledoc """
  Operator-visible verdict on whether the boot codelist seed actually landed.

  A failed seed used to leave exactly one rescued log line. `Barkpark.Codelists.EDItEUR`
  rescues its own seeders and `Plugins.Registry.run_all_codelist_seeders/0` rescues
  the rest, so a boot whose Thema seed died on a statement timeout still finishes
  starting, answers 200, and serves an OnixEdit Thema field with no codes in it.
  This module turns that silence into a named signal on `/status.json`, the status
  page, and the boot log.

  ## Why the check is driven by the EXPECTED ROSTER, not by the table

  The obvious check — "walk the codelists table, complain about lists with no
  values" — CANNOT SEE ITS OWN WORST CASE. `Content.Codelists.register/3` upserts
  the codelist HEADER inside the same transaction as the values, so when a
  first-ever seed rolls back the list is not empty, it is ABSENT: there is no row
  to walk and nothing to complain about. That is precisely the fresh-install
  failure this check exists for.

  So the roster comes from the plugins: every registered plugin that exports
  `codelist_requirements/0` declares `{plugin_name, list_id, issue}` for each list
  its schema references (today: `Barkpark.Plugins.OnixEdit`, 74 lists). The audit
  asks, for each declared requirement, whether the database holds that list at
  that issue with at least one value, and names the ones that do not:

    * `:absent` — no `codelists` row at all for `(plugin_name, list_id)`. The
      fresh-install rollback case, invisible to an emptiness scan.
    * `:empty`  — the row exists at the expected issue and has ZERO values.
    * `:stale`  — rows exist, but none at the issue the plugin currently declares
      (the snapshot moved and the re-seed never landed).

  Declaration is not seeding: a plugin may declare a list its seeders do not
  populate. That is exactly the state an operator wants named — the schema
  references a codelist the box cannot serve — so it is reported, not excluded.

  Pure and injectable: `audit/1` takes `:requirements`, so a caller can audit an
  arbitrary roster without touching the plugin registry.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Content.Codelists.{Codelist, Value}
  alias Barkpark.Repo

  require Logger

  @type requirement :: %{
          required(:plugin_name) => String.t(),
          required(:list_id) => String.t(),
          required(:issue) => String.t()
        }

  @type problem :: %{
          plugin_name: String.t(),
          list_id: String.t(),
          expected_issue: String.t(),
          reason: :absent | :empty | :stale,
          message: String.t()
        }

  @type audit :: %{status: :ok | :degraded, checked: non_neg_integer(), problems: [problem()]}

  @doc """
  The declared codelist roster across every registered plugin.

  `codelist_requirements/0` is a plugin-local declaration, not a
  `Barkpark.Plugin` callback, so this probes for it with `function_exported?/3`
  rather than assuming it. A registry that is not up (or a plugin that raises)
  yields `[]` — a health probe must never be the thing that takes the node down.
  """
  @spec requirements() :: [requirement()]
  def requirements do
    Barkpark.Plugins.Registry.all()
    |> Enum.flat_map(&plugin_requirements/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp plugin_requirements(%{module: module}) when is_atom(module) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :codelist_requirements, 0) do
      module.codelist_requirements() |> List.wrap() |> Enum.filter(&valid_requirement?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp plugin_requirements(_), do: []

  defp valid_requirement?(%{plugin_name: p, list_id: l, issue: i})
       when is_binary(p) and is_binary(l) and is_binary(i),
       do: true

  defp valid_requirement?(_), do: false

  @doc """
  Audit the declared roster against what the database actually holds.

  Options:

    * `:requirements` — the roster to audit (default: `requirements/0`).

  Returns `%{status: :ok | :degraded, checked: n, problems: [...]}`. `:degraded`
  exactly when `problems` is non-empty. An empty roster is `:ok` with
  `checked: 0` — nothing was declared, so nothing is missing.
  """
  @spec audit(keyword()) :: audit()
  def audit(opts \\ []) do
    reqs =
      opts
      |> Keyword.get_lazy(:requirements, &requirements/0)
      |> List.wrap()
      |> Enum.filter(&valid_requirement?/1)
      |> Enum.uniq_by(&{&1.plugin_name, &1.list_id})

    persisted = persisted_index(reqs)
    problems = reqs |> Enum.map(&classify(&1, persisted)) |> Enum.reject(&is_nil/1)

    %{
      status: if(problems == [], do: :ok, else: :degraded),
      checked: length(reqs),
      problems: problems
    }
  end

  # One query for the whole roster: every (plugin_name, list_id, issue) row the
  # roster names, with its value count. `left_join` so a header row with zero
  # values comes back as a 0 rather than vanishing — the `:empty` arm depends
  # on being able to tell "no values" from "no row".
  defp persisted_index([]), do: %{}

  defp persisted_index(reqs) do
    list_ids = reqs |> Enum.map(& &1.list_id) |> Enum.uniq()
    plugin_names = reqs |> Enum.map(& &1.plugin_name) |> Enum.uniq()

    from(c in Codelist,
      left_join: v in Value,
      on: v.codelist_id == c.id,
      where: c.list_id in ^list_ids and c.plugin_name in ^plugin_names,
      group_by: [c.plugin_name, c.list_id, c.issue],
      select: {c.plugin_name, c.list_id, c.issue, count(v.id)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {p, l, _i, _n} -> {p, l} end, fn {_p, _l, i, n} -> {i, n} end)
  end

  defp classify(req, persisted) do
    case Map.get(persisted, {req.plugin_name, req.list_id}, []) do
      [] ->
        problem(req, :absent, "no codelist row exists for plugin #{req.plugin_name}")

      rows ->
        case List.keyfind(rows, req.issue, 0) do
          {_issue, 0} ->
            problem(req, :empty, "registered at issue #{req.issue} with 0 values")

          {_issue, _n} ->
            nil

          nil ->
            have = rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")

            problem(
              req,
              :stale,
              "registered at issue #{have} but the plugin declares issue #{req.issue}"
            )
        end
    end
  end

  defp problem(req, reason, detail) do
    %{
      plugin_name: req.plugin_name,
      list_id: req.list_id,
      expected_issue: req.issue,
      reason: reason,
      message: "codelist #{req.list_id} is empty or stale: #{detail}"
    }
  end

  @doc """
  One line per problem, ready for a log or a status-page detail cell. Empty list
  when the audit is clean.
  """
  @spec messages(audit()) :: [String.t()]
  def messages(%{problems: problems}), do: Enum.map(problems, & &1.message)

  @doc """
  A single operator-readable summary, or `nil` when the audit is clean.

  Truncated to `:limit` named lists (default 5) plus a count of the rest: a
  fresh-install rollback fails all 74 OnixEdit lists at once and a status page
  cell is not the place to print all of them.
  """
  @spec summary(audit(), keyword()) :: String.t() | nil
  def summary(audit, opts \\ [])
  def summary(%{problems: []}, _opts), do: nil

  def summary(%{problems: problems}, opts) do
    limit = Keyword.get(opts, :limit, 5)
    {shown, rest} = Enum.split(problems, limit)
    head = Enum.map_join(shown, "; ", & &1.message)

    case rest do
      [] -> head
      _ -> head <> "; and #{length(rest)} more codelist(s) empty or stale"
    end
  end

  @doc """
  Run the audit and LOG every problem at `:error`, once, at boot.

  Called from `Barkpark.SchemaBootstrap` right after the seeders run, and only
  when they ran — a node configured not to boot-seed codelists (the test env)
  is not missing anything. Returns the audit so a caller can assert on it.
  """
  @spec log_boot_audit(keyword()) :: audit()
  def log_boot_audit(opts \\ []) do
    audit = audit(opts)

    for message <- messages(audit) do
      Logger.error("Barkpark.Content.CodelistHealth: #{message}")
    end

    case audit do
      %{status: :ok, checked: n} when n > 0 ->
        Logger.info(
          "Barkpark.Content.CodelistHealth: #{n} declared codelist(s) present and non-empty"
        )

      _ ->
        :ok
    end

    audit
  end
end
