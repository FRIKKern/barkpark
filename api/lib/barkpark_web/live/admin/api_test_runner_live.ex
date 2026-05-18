defmodule BarkparkWeb.Admin.ApiTestRunnerLive do
  @moduledoc """
  Task barkpark-07s2 — admin LiveView at `/studio/:dataset/_api`.

  Lists every `api_test_spec()` returned by
  `Barkpark.Plugins.Registry.collect_api_tests/1` as a table of rows
  (Name | Method+Path | Auth | Asserts | Status | Run). The page
  carries a top-bar "Run all" button plus per-row Run buttons and a
  per-row collapsible detail pane that surfaces the redacted request
  payload (method, path, headers, body) and the response payload
  (status, body, headers, duration_ms) for the most recent run.

  ## Auth

  Mounted inside the `live_session :admin_studio_dataset` block — same
  `BarkparkWeb.LiveAuth.:admin` on_mount hook as
  `BarkparkWeb.Admin.PluginsLive`.

  ## Execution model (plan §0 Q1, §4)

  Per-run isolation lives in `Barkpark.ApiTestRunner.run_one/3` —
  each spec is wrapped in try/rescue so one misbehaving spec cannot
  crash the rest. The LV fires each Task.async/1 against
  `run_one/3` and streams results back via `handle_info({ref, result},
  socket)`, so the operator sees rows flip from "running" to
  pass/fail/error one by one. Session-scoped — no DB writes.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.ApiTestRunner
  alias Barkpark.Plugins.Registry

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    tests = Registry.collect_api_tests(baseline: [], ctx: %{dataset: dataset})

    {:ok,
     socket
     |> assign(
       page_title: "API tests",
       dataset: dataset,
       base_url: configured_base_url(),
       tests: tests,
       results: empty_results(tests),
       expanded: MapSet.new(),
       running: MapSet.new(),
       pending: %{}
     )}
  end

  # ── events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("run-one", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    case Enum.at(socket.assigns.tests, idx) do
      nil ->
        {:noreply, socket}

      spec ->
        {:noreply, start_run(socket, [{idx, spec}])}
    end
  end

  def handle_event("run-all", _params, socket) do
    pairs = Enum.with_index(socket.assigns.tests) |> Enum.map(fn {s, i} -> {i, s} end)
    {:noreply, start_run(socket, pairs)}
  end

  def handle_event("toggle-detail", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, idx) do
        MapSet.delete(expanded, idx)
      else
        MapSet.put(expanded, idx)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  # ── async result plumbing ───────────────────────────────────────────

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    case Map.pop(socket.assigns.pending, ref) do
      {nil, _} ->
        {:noreply, socket}

      {idx, rest} ->
        Process.demonitor(ref, [:flush])

        {:noreply,
         socket
         |> assign(
           results: List.replace_at(socket.assigns.results, idx, result),
           running: MapSet.delete(socket.assigns.running, idx),
           pending: rest
         )}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Map.pop(socket.assigns.pending, ref) do
      {nil, _} ->
        {:noreply, socket}

      {idx, rest} ->
        crash_result = %{
          name: "(crashed)",
          spec: %{},
          request: nil,
          response: nil,
          asserts: [{:exception, :error, inspect(reason)}],
          cleanup: [],
          duration_ms: 0,
          status: :error,
          error_message: inspect(reason)
        }

        {:noreply,
         socket
         |> assign(
           results: List.replace_at(socket.assigns.results, idx, crash_result),
           running: MapSet.delete(socket.assigns.running, idx),
           pending: rest
         )}
    end
  end

  # Start a list of `{index, spec}` runs in parallel via Task.async.
  defp start_run(socket, pairs) do
    base_url = socket.assigns.base_url

    {running, pending} =
      Enum.reduce(pairs, {socket.assigns.running, socket.assigns.pending}, fn {idx, spec},
                                                                              {run_acc, pend_acc} ->
        task = Task.async(fn -> ApiTestRunner.run_one(spec, base_url) end)
        {MapSet.put(run_acc, idx), Map.put(pend_acc, task.ref, idx)}
      end)

    # Clear stale results for rows we just kicked off so the badge flips
    # to "running" cleanly.
    results =
      Enum.reduce(pairs, socket.assigns.results, fn {idx, _}, acc ->
        List.replace_at(acc, idx, nil)
      end)

    assign(socket, running: running, pending: pending, results: results)
  end

  # ── render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bp-api-test-runner" data-test-id="api-test-runner">
      <div class="bp-api-test-header">
        <h1 class="h1">API tests</h1>
        <div class="bp-api-test-actions">
          <button
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="run-all"
            phx-disable-with="Running…"
            data-test-action="run-all"
            disabled={@tests == []}
          >
            Run all
          </button>
        </div>
      </div>

      <p class="bp-api-test-meta text-muted">
        Dataset <strong>{@dataset}</strong> · base URL <code>{@base_url}</code> · {length(@tests)} test(s).
        Results are session-scoped — nothing is persisted.
      </p>

      <%= if @tests == [] do %>
        <p class="bp-api-test-empty" data-test-id="api-test-empty">
          No tests registered. Plugins contribute via <code>api_tests/0</code>.
        </p>
      <% else %>
        <table class="bp-api-test-table" data-test-id="api-test-table">
          <thead>
            <tr>
              <th class="bp-api-test-col-status">Status</th>
              <th class="bp-api-test-col-name">Name</th>
              <th class="bp-api-test-col-route">Method &amp; path</th>
              <th class="bp-api-test-col-auth">Auth</th>
              <th class="bp-api-test-col-asserts">Asserts</th>
              <th class="bp-api-test-col-actions"></th>
            </tr>
          </thead>
          <tbody>
            <%= for {spec, idx} <- Enum.with_index(@tests) do %>
              <.test_row
                spec={spec}
                idx={idx}
                result={Enum.at(@results, idx)}
                running={MapSet.member?(@running, idx)}
                expanded={MapSet.member?(@expanded, idx)}
              />
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  # Single-row component — header line plus an optional expanded
  # detail pane that renders the redacted request and response.
  attr :spec, :map, required: true
  attr :idx, :integer, required: true
  attr :result, :any, default: nil
  attr :running, :boolean, default: false
  attr :expanded, :boolean, default: false

  defp test_row(assigns) do
    ~H"""
    <tr
      class="bp-api-test-row"
      data-test-id="api-test-row"
      data-test-index={@idx}
      data-test-status={status_data(@running, @result)}
    >
      <td class="bp-api-test-col-status">
        <span class={"bp-api-test-status " <> status_class(@running, @result)}>
          {status_label(@running, @result)}
        </span>
      </td>
      <td class="bp-api-test-col-name">
        <strong>{Map.get(@spec, :name, "(unnamed)")}</strong>
        <%= if @result && @result.error_message do %>
          <div class="bp-api-test-err">{@result.error_message}</div>
        <% end %>
      </td>
      <td class="bp-api-test-col-route">
        <code>{format_method(Map.get(@spec, :method))} {Map.get(@spec, :path, "")}</code>
      </td>
      <td class="bp-api-test-col-auth">
        <code>{format_auth(Map.get(@spec, :auth, :none))}</code>
      </td>
      <td class="bp-api-test-col-asserts">
        {length(Map.get(@spec, :asserts, []))}
      </td>
      <td class="bp-api-test-col-actions">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="run-one"
          phx-value-index={@idx}
          phx-disable-with="…"
          data-test-action="run-one"
          disabled={@running}
        >
          Run
        </button>
        <button
          type="button"
          class="btn btn-sm bp-api-test-toggle"
          phx-click="toggle-detail"
          phx-value-index={@idx}
          data-test-action="toggle-detail"
        >
          {if @expanded, do: "Hide", else: "Detail"}
        </button>
      </td>
    </tr>
    <%= if @expanded do %>
      <tr class="bp-api-test-detail" data-test-id="api-test-detail" data-test-index={@idx}>
        <td colspan="6">
          <%= if @result do %>
            <div class="bp-api-test-panes">
              <div class="bp-api-test-pane">
                <h4>Request</h4>
                <%= if @result.request do %>
                  <pre><code>{inspect_payload(@result.request)}</code></pre>
                <% else %>
                  <p class="text-dim">No request captured.</p>
                <% end %>
              </div>
              <div class="bp-api-test-pane">
                <h4>Response</h4>
                <%= if @result.response do %>
                  <pre><code>{inspect_payload(@result.response)}</code></pre>
                <% else %>
                  <p class="text-dim">No response (request errored).</p>
                <% end %>
              </div>
              <%= if @result.asserts != [] do %>
                <div class="bp-api-test-pane">
                  <h4>Asserts</h4>
                  <ul class="bp-api-test-asserts">
                    <%= for {tag, kind, msg} <- @result.asserts do %>
                      <li class={"bp-api-test-assert bp-api-test-assert-" <> Atom.to_string(kind)}>
                        <code>{inspect(tag)}</code>
                        <span class="bp-api-test-assert-kind">{kind}</span>
                        <%= if msg && msg != "" do %>
                          <span class="bp-api-test-assert-msg">— {msg}</span>
                        <% end %>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="text-dim">Not run yet.</p>
          <% end %>
        </td>
      </tr>
    <% end %>
    """
  end

  # ── presentation helpers ────────────────────────────────────────────

  defp status_label(true, _), do: "running"
  defp status_label(false, nil), do: "not run"
  defp status_label(false, %{status: :pass}), do: "pass"
  defp status_label(false, %{status: :fail}), do: "fail"
  defp status_label(false, %{status: :error}), do: "error"
  defp status_label(_, _), do: "not run"

  defp status_class(true, _), do: "bp-api-test-status-running"
  defp status_class(false, nil), do: "bp-api-test-status-not-run"
  defp status_class(false, %{status: :pass}), do: "bp-api-test-status-pass"
  defp status_class(false, %{status: :fail}), do: "bp-api-test-status-fail"
  defp status_class(false, %{status: :error}), do: "bp-api-test-status-error"
  defp status_class(_, _), do: "bp-api-test-status-not-run"

  defp status_data(true, _), do: "running"
  defp status_data(false, nil), do: "not-run"
  defp status_data(false, %{status: s}), do: Atom.to_string(s)
  defp status_data(_, _), do: "not-run"

  defp format_method(nil), do: "GET"
  defp format_method(m) when is_atom(m), do: m |> Atom.to_string() |> String.upcase()
  defp format_method(m) when is_binary(m), do: String.upcase(m)
  defp format_method(_), do: "GET"

  defp format_auth(:none), do: "none"
  defp format_auth(:admin), do: "admin"
  defp format_auth({:token, _}), do: "token"
  defp format_auth({:plugin_setting, key}), do: "plugin_setting:" <> key
  defp format_auth(other), do: inspect(other)

  defp inspect_payload(payload) when is_map(payload) do
    payload
    |> Enum.to_list()
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{inspect_value(v)}" end)
  end

  defp inspect_payload(other), do: inspect(other, pretty: true, limit: :infinity)

  defp inspect_value(v) when is_binary(v) do
    if String.length(v) > 1200, do: String.slice(v, 0, 1199) <> "…", else: v
  end

  defp inspect_value(v), do: inspect(v, pretty: true, limit: 200)

  # ── data loaders ────────────────────────────────────────────────────

  defp empty_results(tests), do: List.duplicate(nil, length(tests))

  defp configured_base_url do
    Application.get_env(:barkpark, :api_test_runner_base_url, "http://localhost:4000")
  end
end
