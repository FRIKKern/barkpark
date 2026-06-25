defmodule Barkpark.ApiTester.Endpoints do
  @moduledoc """
  Single source of truth for the Studio API Docs + Playground pane.

  Each entry describes an endpoint (or a reference page) with enough
  metadata to render both the documentation column AND the interactive
  playground form: method, path template, auth level, typed params,
  example body, response shape, and possible errors.

  The `Barkpark.ApiTester.Runner` consumes this together with form
  state from the LiveView to build concrete HTTP requests.

  ## Facade

  This module is a thin **facade**. The catalog entries live in
  per-category sibling modules under `endpoints/` — each exposes
  `entries/1` returning ITS slice of the catalog (maps moved verbatim,
  same keys/values, same dataset interpolation):

    * `Endpoints.Reference` — envelope / error-codes / known-limitations
    * `Endpoints.Query`     — list / filter-ops / single / expand / search
    * `Endpoints.Mutate`    — the 8 mutation kinds
    * `Endpoints.Export`    — NDJSON dataset export
    * `Endpoints.History`   — list / show / restore revisions
    * `Endpoints.Misc`      — analytics + SSE listen (singletons)
    * `Endpoints.Schemas`   — list / show + the live schema-browser ref
    * `Endpoints.Webhooks`  — list / create / delete

  `all/1` concatenates those slices **in the original order** and appends
  the dynamic plugin-contributed entries. `find/2` is a search over
  `all/1`. The public surface (`all/1`, `find/2`) is byte-identical to
  before the split — those are the only callers (api_tester_live.ex).

  ## Spec shape

      %{
        id:            "query-list",              # stable slug
        category:      "Query",                   # nav group heading
        label:         "List documents",          # short name in nav
        kind:          :endpoint | :reference,    # :endpoint has a playground
        auth:          :public | :token | :admin, # controls token badge in docs
        method:        "GET" | "POST" | ...,
        path_template: "/v1/data/query/{dataset}/{type}",
        description:   "Short paragraph (< 200 chars).",
        path_params:   [param_spec()],
        query_params:  [param_spec()],
        body_example:  nil | map(),               # JSON body seed for the form
        response_shape: "abbreviated JSON example",
        possible_errors: [atom()],                # matches Errors.to_envelope codes
        expect:        {integer(), atom()} | nil  # verdict predicate (see Runner)
      }

  Reference entries set `kind: :reference` and carry a `render_key`
  atom instead of params/body; the LiveView has a clause per render_key.

  ## Param spec

      %{
        name:     "limit",
        type:     :string | :integer | :select | :json,
        default:  "10",
        options:  [...]     # for :select
        notes:    "Integer, min 1, max 1000"
      }
  """

  alias Barkpark.ApiTester.Endpoints.{
    Export,
    History,
    Misc,
    Mutate,
    Query,
    Reference,
    Schemas,
    Webhooks
  }

  @spec all(String.t()) :: [map()]
  def all(dataset) when is_binary(dataset) do
    # Concatenated IN THE ORIGINAL ORDER the entries appeared in the
    # pre-split module — the LiveView renders the nav in this order, so it
    # must be preserved exactly. Each category module returns its slice.
    host =
      Reference.entries(dataset) ++
        Query.entries(dataset) ++
        Mutate.entries(dataset) ++
        Export.entries(dataset) ++
        History.entries(dataset) ++
        Misc.entries(dataset) ++
        Schemas.entries(dataset) ++
        Webhooks.entries(dataset)

    host ++ plugin_endpoints(dataset)
  end

  # Task barkpark-7xne — pull plugin-contributed api_tests/0 specs from
  # the Registry and adapt them into the Endpoints shape so they appear
  # in the legacy ApiTesterLive sidebar as a "Plugins" category. The
  # ApiTesterLive playground can render docs + form for these entries
  # like any other endpoint.
  #
  # NOTE: clicking "Run" on a plugin entry currently fires the bare
  # request via the existing Runner — it does NOT yet evaluate the
  # plugin spec's `:asserts` chain. Full assert-evaluation belongs to
  # `Barkpark.ApiTestRunner.run_one/3`; wiring that into ApiTesterLive
  # is a TODO for a follow-up commit. The immediate user-visible fix
  # is restoring the rich sidebar UI.
  defp plugin_endpoints(dataset) do
    try do
      Barkpark.Plugins.Registry.collect_api_tests(baseline: [], ctx: %{dataset: dataset})
    rescue
      _ -> []
    catch
      _, _ -> []
    end
    |> Enum.with_index()
    |> Enum.map(fn {spec, idx} -> plugin_spec_to_endpoint(spec, idx) end)
  end

  defp plugin_spec_to_endpoint(spec, index) do
    asserts = Map.get(spec, :asserts, []) || []
    expected_status = expected_status_from_asserts(asserts)

    %{
      id: "plugin-" <> slugify(spec.name) <> "-" <> to_string(index),
      category: "Plugins",
      label: spec.name,
      kind: :endpoint,
      auth: plugin_auth_to_auth_level(Map.get(spec, :auth, :none)),
      method: spec.method |> to_string() |> String.upcase(),
      path_template: spec.path,
      description: "Plugin-contributed test. Asserts: " <> describe_asserts(asserts),
      path_params: [],
      query_params: [],
      body_example: Map.get(spec, :body),
      response_shape: "Plugin spec — see the assert list above for the expected shape.",
      possible_errors: [],
      expect: {expected_status, :ok},
      runnable: true,
      plugin_spec: spec
    }
  end

  defp plugin_auth_to_auth_level(:none), do: :public
  defp plugin_auth_to_auth_level(:admin), do: :admin
  defp plugin_auth_to_auth_level({:token, _}), do: :token
  defp plugin_auth_to_auth_level({:plugin_setting, _}), do: :token
  defp plugin_auth_to_auth_level(_), do: :public

  defp expected_status_from_asserts(asserts) when is_list(asserts) do
    Enum.find_value(asserts, 200, fn
      {:status, n} when is_integer(n) -> n
      _ -> nil
    end)
  end

  defp expected_status_from_asserts(_), do: 200

  defp describe_asserts([]), do: "(none)"

  defp describe_asserts(asserts) do
    asserts
    |> Enum.map(&describe_assert/1)
    |> Enum.join(", ")
  end

  defp describe_assert({:status, n}), do: "status=#{n}"
  defp describe_assert({:body_contains, s}), do: "body~\"#{s}\""
  defp describe_assert({:body_regex, _re}), do: "body matches regex"
  defp describe_assert({:json_path, path, _fn}), do: "json[#{Enum.join(path, ".")}] predicate"
  defp describe_assert({:json_keys_include, keys}), do: "json keys ⊇ #{Enum.join(keys, ",")}"
  defp describe_assert({:header, name, _v}), do: "header #{name}"
  defp describe_assert(:not_empty), do: "not_empty"
  defp describe_assert({:duration_under_ms, n}), do: "<#{n}ms"
  defp describe_assert(other), do: inspect(other)

  defp slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "test"
      s -> s
    end
  end

  @spec find(String.t(), String.t()) :: map() | nil
  def find(dataset, id) when is_binary(dataset) and is_binary(id) do
    Enum.find(all(dataset), &(&1.id == id))
  end
end
