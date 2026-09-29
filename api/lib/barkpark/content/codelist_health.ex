defmodule Barkpark.Content.CodelistHealth do
  @moduledoc """
  Operator-visible verdict on whether the boot codelist seed actually landed.

  A failed seed used to leave exactly one rescued log line. `Barkpark.Codelists.EDItEUR`
  rescues its own seeders and the registry's `run_all_codelist_seeders/0` rescues
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

  So the roster is DECLARED by the plugins and arrives here through an injected
  collector (`:codelist_requirements_collector`, installed at the composition
  root): every registered plugin that exports `codelist_requirements/0` declares
  `{plugin_name, list_id, issue}` for each list its schema references (today:
  the OnixEdit plugin, 74 lists). This module names no plugin module and
  no registry — the kernel does not reach into the plugin layer. The audit
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
  arbitrary roster, and the default roster itself arrives through the seam.
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

  # The INVERTED codelist-requirements seam. `content` is a KERNEL concept and
  # the plugin registry is a FEATURE, so the kernel must hold no
  # compile-time reference to it — the same rule `Barkpark.Content.Graph`'s
  # `:edge_extractor_collector` already obeys. The composition root
  # (`Barkpark.Application.start/2`, the ONE installer) hands the plugin-roster
  # fan-out DOWN into this key; `requirements/0` only READS it.
  @requirements_collector_key :codelist_requirements_collector

  @doc """
  The declared codelist roster, as handed in through the injected collector.

  Two installable shapes, exactly as the edge-extractor seam accepts:

    * a 0-arity fun (what the boot installer captures), and
    * a `{module, function}` pair, so a release or a config file can wire the
      seam without the OTP app having started.

  UNSET yields `[]` — the fresh-install invariant: a plugin-free host (or a
  script, or a test that never booted the app) declares no codelists, so
  nothing is missing and `audit/1` is `:ok`. A garbage value, a collector that
  raises, or a plugin that raises yields `[]` too: a health probe must never be
  the thing that takes the node down.
  """
  @spec requirements() :: [requirement()]
  def requirements do
    case Application.get_env(:barkpark, @requirements_collector_key) do
      collector when is_function(collector, 0) -> collector.() |> List.wrap()
      {mod, fun} when is_atom(mod) and is_atom(fun) -> apply(mod, fun, []) |> List.wrap()
      _ -> []
    end
    |> Enum.filter(&valid_requirement?/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

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
