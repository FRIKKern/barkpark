defmodule Barkpark.Plugins.Census do
  @moduledoc """
  Release-boot plugin census — the one host-side answer to "which plugins
  actually registered their schemas in THIS running image?".

  ## Why this exists

  `Barkpark.Plugins.Bootstrap` is deliberately degradation-tolerant: a plugin
  that raises inside `register_schemas/1` is rescued, logged, and skipped, and
  `register_all_schemas/0` returns `{:error, errors}` without raising
  (`bootstrap.ex`, `do_install_for_plugin/3`). Boot continues. The container
  therefore reaches healthcheck-healthy and `GET /api/schemas` answers 200
  with whatever schemas DID register.

  That is why compose-smoke's green arm reported PASS for weeks while six of
  nine plugins were dead in every released build (PR #13708 /
  task-f44c1839cb28b0af). HTTP liveness cannot distinguish "the stack booted"
  from "the stack booted correctly", and no probe built on liveness ever will.

  This module makes the CURRENT behaviour visible. It does NOT change it —
  whether that rescue should stay a logged degradation or become a boot
  refusal is a separate, still-open disposition (parent task-a6ef8e3b2c78054f,
  criterion 3). Nothing here should be read as having settled it.

  ## What it reads

  Registration OUTCOME, never liveness:

    * `Barkpark.Plugins.Registry.all/0` — the plugins this node actually has.
    * `Barkpark.Plugins.RunStatus` — what `Bootstrap.install_for_plugin/2`
      recorded for each of them when `register_all_schemas/0` walked the
      registry at boot (`:bootstrap` result + the `:schemas` type names that
      landed).

  It never calls a plugin module. The census is HOST code reading the host's
  own registry, so it holds with every plugin removed — an empty plugin set
  is an empty SUCCESSFUL census, not an error (repo doctrine: with all
  plugins off, Barkpark still works).

  ## The contract (for the compose-smoke green arm)

  Entry point for a booted release image:

      bin/barkpark rpc 'Barkpark.Plugins.Census.cli()'

  It prints one line of JSON to stdout and halts `0` on a healthy census,
  `1` when any plugin failed. Callers that want the data without the halt use
  `report_json/1` (a JSON string) or `take/1` / `check/1` (Elixir terms).

  The JSON envelope, stable and machine-readable:

      {
        "ok": true,
        "plugin_count": 9,
        "schema_count": 14,
        "failed": [],
        "plugins": [
          {
            "name": "onixedit",
            "module": "Elixir.Barkpark.Plugins.OnixEdit",
            "status": "ok",
            "schema_count": 2,
            "schemas": ["book", "contributor"],
            "error": null
          }
        ]
      }

  Field meanings:

    * `ok` — `false` iff at least one plugin has a non-`"ok"` status. This is
      the assertion the gate should make; `cli/0`'s exit code mirrors it.
    * `plugin_count` / `schema_count` — plugins in the registry, and schema
      rows those plugins installed or refreshed on this boot.
    * `failed` — the plugin names whose status is not `"ok"`, so a gate can
      print the culprits without walking `plugins`.
    * `plugins[].status` — one of:
        * `"ok"` — `register_schemas/1` ran and every emitted schema upserted.
        * `"failed"` — the callback raised, returned a non-list, or an upsert
          was refused. `error` carries the inspected reason.
        * `"module_not_loaded"` — the plugin is registered but its module is
          not loadable in this image. Bootstrap logs and returns `{:ok, 0}`
          for this today, which is exactly the silent death the census exists
          to expose, so the census calls it a failure.
        * `"not_registered"` — the plugin is in the registry but nothing was
          ever recorded for it: `register_all_schemas/0` never reached it.
    * `plugins[].schemas` — the schema type NAMES installed by that plugin,
      sorted; `schema_count` is its length. A plugin with no
      `register_schemas/1` callback is `"ok"` with an empty list.

  Plugins are sorted by name so two runs of the same image diff cleanly.
  """

  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.RunStatus

  @type plugin_row :: %{
          name: String.t(),
          module: String.t(),
          status: String.t(),
          schema_count: non_neg_integer(),
          schemas: [String.t()],
          error: String.t() | nil
        }

  @type report :: %{
          ok: boolean(),
          plugin_count: non_neg_integer(),
          schema_count: non_neg_integer(),
          failed: [String.t()],
          plugins: [plugin_row()]
        }

  @doc """
  Builds the census for this node. See the module doc for the shape.

  Options (both exist so the census can be exercised without a live boot;
  production callers pass none):

    * `:plugins` — the registry entries to census. Defaults to
      `Registry.all/0`.
    * `:status` — the recorded run-status map. Defaults to `RunStatus.all/0`.
  """
  # @canonical capability:release-boot-plugin-census aka:plugin census,which plugins registered,schema registration outcome,compose-smoke plugin assertion
  @spec take(keyword()) :: report()
  def take(opts \\ []) do
    plugins = Keyword.get_lazy(opts, :plugins, &Registry.all/0)
    status = Keyword.get_lazy(opts, :status, &RunStatus.all/0)

    rows =
      plugins
      |> Enum.map(&row_for(&1, Map.get(status, plugin_name(&1), %{})))
      |> Enum.sort_by(& &1.name)

    failed = rows |> Enum.reject(&(&1.status == "ok")) |> Enum.map(& &1.name)

    %{
      ok: failed == [],
      plugin_count: length(rows),
      schema_count: rows |> Enum.map(& &1.schema_count) |> Enum.sum(),
      failed: failed,
      plugins: rows
    }
  end

  @doc """
  `{:ok, report}` when every plugin registered, `{:error, report}` when any
  did not. Same report either way — the tag is the signal.
  """
  @spec check(keyword()) :: {:ok, report()} | {:error, report()}
  def check(opts \\ []) do
    report = take(opts)
    if report.ok, do: {:ok, report}, else: {:error, report}
  end

  @doc """
  The census as one line of JSON — the documented envelope in the module doc.
  """
  @spec report_json(keyword()) :: String.t()
  def report_json(opts \\ []), do: opts |> take() |> Jason.encode!()

  @doc """
  Release entry point: print the JSON envelope and halt `0` / `1`.

      bin/barkpark rpc 'Barkpark.Plugins.Census.cli()'

  Halts rather than returning so a shell gate can read the exit code without
  parsing stdout. Use `check/1` when you want the term.
  """
  @spec cli(keyword()) :: no_return()
  def cli(opts \\ []) do
    report = take(opts)
    IO.puts(Jason.encode!(report))
    System.halt(if report.ok, do: 0, else: 1)
  end

  # ── row construction ──────────────────────────────────────────────────────

  defp plugin_name(%{name: name}), do: name

  defp row_for(%{name: name, module: module}, recorded) do
    {status, error, schemas} = classify(recorded)

    %{
      name: name,
      module: inspect_module(module),
      status: status,
      schema_count: length(schemas),
      schemas: schemas,
      error: error
    }
  end

  # Nothing recorded at all: `register_all_schemas/0` never walked this
  # plugin. Silence is the one outcome a liveness probe also produces, so the
  # census must NOT read it as health.
  defp classify(recorded) when map_size(recorded) == 0,
    do: {"not_registered", "no registration outcome recorded for this plugin", []}

  defp classify(recorded) do
    schemas = recorded |> Map.get(:schemas, %{}) |> installed_names()

    case Map.get(recorded, :bootstrap) do
      nil ->
        {"not_registered", "no registration outcome recorded for this plugin", schemas}

      %{result: {:ok, _n}} ->
        case detail(recorded) do
          :module_not_loaded ->
            {"module_not_loaded", "plugin module failed to load in this image", schemas}

          _ ->
            {"ok", nil, schemas}
        end

      %{result: {:error, reason}} ->
        {"failed", inspect(reason), schemas}

      %{result: other} ->
        {"failed", "unrecognised bootstrap result: #{inspect(other)}", schemas}
    end
  end

  defp installed_names(%{result: %{names: names}}) when is_list(names), do: Enum.sort(names)
  defp installed_names(_), do: []

  defp detail(recorded) do
    case Map.get(recorded, :schemas) do
      %{result: %{detail: detail}} -> detail
      _ -> nil
    end
  end

  defp inspect_module(module) when is_atom(module), do: Atom.to_string(module)
  defp inspect_module(other), do: inspect(other)
end
