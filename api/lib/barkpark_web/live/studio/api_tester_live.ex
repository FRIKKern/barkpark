defmodule BarkparkWeb.Studio.ApiTesterLive do
  @moduledoc """
  Studio pane: interactive v1 API Docs + Playground.

  Three-column layout:
  - Left sidebar: endpoint list grouped by category
  - Centre: docs (description, params, response shape) + form-driven playground
  - Right: last response (status, duration, headers, pretty JSON body) with pass/fail badge

  Dispatch is server-side via :httpc — the requests hit the same Phoenix
  endpoint that is serving this LiveView, so network/TLS/CORS specifics
  are out of scope here. For browser-origin checks use the CORS section
  of the docs/api-v1.md reference.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.ApiTester.{Endpoints, Runner}
  alias BarkparkWeb.Studio.Caps
  import BarkparkWeb.Studio.ApiTesterLive.Format
  import BarkparkWeb.Studio.ApiTesterLive.Request
  import BarkparkWeb.Studio.ApiTesterLive.Components

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    endpoints = Endpoints.all(dataset)
    selected = List.first(endpoints) || %{id: nil}

    form_state_by_id =
      endpoints
      |> Enum.filter(&(&1.kind == :endpoint))
      |> Enum.into(%{}, fn ep -> {ep.id, initial_form_state(ep)} end)

    # Collapsible categories: empty MapSet == all expanded. Flipping a
    # category name into the set hides its items in the nav.
    {:ok,
     assign(socket,
       nav_section: :api_tester,
       dataset: dataset,
       endpoints: endpoints,
       categories: endpoints |> Enum.map(& &1.category) |> Enum.uniq(),
       collapsed_categories: MapSet.new(),
       selected_id: selected.id,
       # Default the playground token to the CALLER'S OWN raw token (from the
       # session, via LiveAuth :fetch_api_token), never the all-perms
       # barkpark-dev-token. A run then carries the caller's real authority, and
       # an empty string (unauthenticated) sends no bearer rather than leaking a
       # god token into the form.
       token: socket.assigns[:api_token_raw] || "",
       form_state_by_id: form_state_by_id,
       last_result_by_id: %{},
       scenario_results: [],
       # In-flight guard. A run dispatches its blocking :httpc work to a Task so
       # the LiveView process stays responsive; `running` disables the Run /
       # Run-all buttons for the duration and `run_task_ref` is the monitor ref
       # we match the completion message against.
       running: false,
       run_task_ref: nil
     )}
  end

  # A stale phx-value-id (an endpoint from a prior dataset/scope) resolves
  # to nil via Endpoints.find/2 — tolerate it here so the callers don't
  # BadMapError deref a nil endpoint.
  defp initial_form_state(nil), do: %{}

  defp initial_form_state(%{kind: :reference}), do: %{}

  defp initial_form_state(endpoint) do
    body_text =
      if endpoint[:body_example], do: Jason.encode!(endpoint.body_example, pretty: true), else: ""

    path_values =
      Enum.into(endpoint.path_params || [], %{}, fn %{name: name, default: default} ->
        {name, to_string(default)}
      end)

    query_values =
      Enum.into(endpoint.query_params || [], %{}, fn %{name: name, default: default} ->
        {name, to_string(default)}
      end)

    path_values
    |> Map.merge(query_values)
    |> Map.put("_body_text", body_text)
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    endpoint = Endpoints.find(socket.assigns.dataset, id)

    if endpoint == nil do
      # Stale id from a prior dataset — leave the current selection intact.
      {:noreply, put_flash(socket, :error, "Unknown endpoint")}
    else
      # Seed form state lazily if this is the first time selecting this endpoint
      form_state =
        Map.get_lazy(socket.assigns.form_state_by_id, id, fn ->
          initial_form_state(endpoint)
        end)

      new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, form_state)

      {:noreply,
       assign(socket,
         selected_id: id,
         form_state_by_id: new_form_state_by_id,
         scenario_results: []
       )}
    end
  end

  def handle_event("form-change", params, socket) do
    id = socket.assigns.selected_id
    current = Map.get(socket.assigns.form_state_by_id, id, %{})
    # Merge new form params on top, keeping existing ones for fields not in this event
    updated = Map.merge(current, Map.drop(params, ["_target"]))
    new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, updated)
    {:noreply, assign(socket, form_state_by_id: new_form_state_by_id)}
  end

  # NOT orphaned: the top-bar Token field in layouts/studio.html.heex (the
  # `<form phx-change="token-change">` shown while nav_section == :api_tester)
  # dispatches this so an operator can override the run token inline.
  def handle_event("token-change", %{"token" => token}, socket) do
    {:noreply, assign(socket, token: token)}
  end

  def handle_event("toggle-category", %{"category" => category}, socket) do
    collapsed = socket.assigns.collapsed_categories

    new_collapsed =
      if MapSet.member?(collapsed, category) do
        MapSet.delete(collapsed, category)
      else
        MapSet.put(collapsed, category)
      end

    {:noreply, assign(socket, collapsed_categories: new_collapsed)}
  end

  # A run is already in flight — ignore the re-fire. The button is disabled
  # client-side (see `running` assign + the .phx-click-loading CSS), this is
  # the server-side belt-and-suspenders against a double dispatch.
  def handle_event(event, _, %{assigns: %{running: true}} = socket)
      when event in ["run", "run-all"] do
    {:noreply, socket}
  end

  def handle_event("run", _, socket) do
    if not Caps.derive(socket).admin do
      {:noreply, deny_run(socket)}
    else
      do_run(socket)
    end
  end

  def handle_event("run-all", _, socket) do
    if not Caps.derive(socket).admin do
      {:noreply, deny_run(socket)}
    else
      do_run_all(socket)
    end
  end

  # Fall-through: a stale/unknown phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  def handle_event(event, _params, socket) do
    Logger.warning("studio: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # The playground dispatches REAL authenticated HTTP against the live endpoint
  # with the form's token. Only an admin principal (fresh Caps.derive) may fire
  # it — a non-admin member is denied here, mirroring the Studio caps deny-gate.
  defp deny_run(socket),
    do: put_flash(socket, :error, "Admin access required to run API requests.")

  defp do_run(socket) do
    endpoint = Endpoints.find(socket.assigns.dataset, socket.assigns.selected_id)

    if endpoint == nil || endpoint.kind == :reference || endpoint[:runnable] == false do
      {:noreply, assign(socket, scenario_results: [])}
    else
      # Snapshot everything the run needs off the socket, then do the blocking
      # :httpc work inside a Task so the LiveView process isn't frozen. The
      # result comes back as an {ref, msg} message handled below.
      form_state = Map.get(socket.assigns.form_state_by_id, endpoint.id, %{})
      token = socket.assigns.token
      base = runner_base(socket)

      task =
        Task.async(fn ->
          {:run_result, endpoint.id, run_single(endpoint, form_state, token, base)}
        end)

      {:noreply, assign(socket, running: true, run_task_ref: task.ref, scenario_results: [])}
    end
  end

  defp do_run_all(socket) do
    config = %{token: socket.assigns.token, base: runner_base(socket)}
    endpoints = socket.assigns.endpoints

    task = Task.async(fn -> {:run_all_result, run_all_scenarios(endpoints, config)} end)

    {:noreply, assign(socket, running: true, run_task_ref: task.ref)}
  end

  # The blocking run-all sweep, extracted so it can run inside a Task off the
  # LiveView process. Returns {scenario_results, last_results}.
  defp run_all_scenarios(endpoints, config) do
    scenario_results =
      endpoints
      |> Enum.filter(&(&1.kind == :endpoint && &1[:runnable] != false))
      |> Enum.flat_map(fn ep ->
        scenarios = Map.get(ep, :scenarios, [])

        scenarios =
          if scenarios == [] && ep[:expect] do
            [
              %{
                label: "default",
                path_overrides: %{},
                query_overrides: %{},
                body: nil,
                expect: ep.expect
              }
            ]
          else
            scenarios
          end

        if scenarios == [] do
          []
        else
          Enum.map(scenarios, fn scenario ->
            # Build form state from defaults + overrides
            base_form = initial_form_state(ep)

            form_state =
              base_form
              |> Map.merge(scenario[:path_overrides] || %{})
              |> Map.merge(scenario[:query_overrides] || %{})

            # Handle body
            form_state =
              if scenario[:body] do
                Map.put(form_state, "_body_text", Jason.encode!(scenario[:body]))
              else
                form_state
              end

            # Handle auth override (for "no auth" scenarios)
            test_config = if scenario[:no_auth], do: Map.put(config, :token, ""), else: config

            req = Runner.build_request(ep, form_state, test_config)

            legacy = %{
              id: ep.id,
              method: req.method,
              path: String.replace_prefix(req.url, "http://localhost:4000", ""),
              headers: req.headers,
              body: decode_body(req.body_text),
              expect: scenario.expect
            }

            result = Runner.run(legacy)

            %{
              endpoint_id: ep.id,
              endpoint_label: ep.label,
              category: ep.category,
              label: scenario.label,
              result: result
            }
          end)
        end
      end)

    # Also populate last_result_by_id with the first scenario result per endpoint for sidebar badges
    last_results =
      scenario_results
      |> Enum.group_by(& &1.endpoint_id)
      |> Enum.into(%{}, fn {ep_id, srs} ->
        # Composite: if any fail, show fail; else if any error, show error; else pass
        worst =
          cond do
            Enum.any?(srs, &(&1.result.verdict == :fail)) ->
              Enum.find(srs, &(&1.result.verdict == :fail)).result

            Enum.any?(srs, &(&1.result.verdict == :error)) ->
              Enum.find(srs, &(&1.result.verdict == :error)).result

            true ->
              List.first(srs).result
          end

        {ep_id, worst}
      end)

    {scenario_results, last_results}
  end

  # Single-endpoint run, extracted so it can run inside a Task. Returns the
  # verdict result map for `endpoint`.
  defp run_single(endpoint, form_state, token, base) do
    req = Runner.build_request(endpoint, form_state, %{token: token, base: base})

    legacy = %{
      id: endpoint.id,
      method: req.method,
      path: String.replace_prefix(req.url, "http://localhost:4000", ""),
      headers: req.headers,
      body: decode_body(req.body_text),
      expect: endpoint[:expect]
    }

    result = Runner.run(legacy)

    if plugin_spec = endpoint[:plugin_spec] do
      enrich_with_plugin_asserts(result, plugin_spec, token: token, base: base)
    else
      result
    end
  end

  @impl true
  # Single-endpoint run finished. Merge the one result into the badge map and
  # drop the in-flight flag.
  def handle_info(
        {ref, {:run_result, endpoint_id, result}},
        %{assigns: %{run_task_ref: ref}} = socket
      ) do
    Process.demonitor(ref, [:flush])
    new_results = Map.put(socket.assigns.last_result_by_id, endpoint_id, result)

    {:noreply,
     assign(socket,
       last_result_by_id: new_results,
       running: false,
       run_task_ref: nil
     )}
  end

  # Run-all sweep finished.
  def handle_info(
        {ref, {:run_all_result, {scenario_results, last_results}}},
        %{assigns: %{run_task_ref: ref}} = socket
      ) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       scenario_results: scenario_results,
       last_result_by_id: last_results,
       running: false,
       run_task_ref: nil
     )}
  end

  # A run Task crashed (Runner.run swallows HTTP errors, so this is rare). Clear
  # the in-flight flag so the buttons re-enable instead of latching forever.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{run_task_ref: ref}} = socket) do
    if reason != :normal, do: Logger.warning("api-tester run task crashed: #{inspect(reason)}")
    {:noreply, assign(socket, running: false, run_task_ref: nil)}
  end

  # Stale Task messages (a superseded run's ref) — ignore.
  def handle_info({ref, _}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  @doc false
  # Plugin entries carry a :plugin_spec map (see Endpoints.plugin_spec_to_endpoint/2).
  # After Runner.run fires the bare HTTP, evaluate each assert in the spec's
  # :asserts list against the response, then fire any :cleanup steps. Cleanup
  # always runs regardless of pass/fail (matches ApiTestRunner's plan §0 Q1).
  #
  # Runner.run/2 returns body in :body_text; Asserts.evaluate/2 expects :body.
  # We re-map field names here rather than touching the Runner.
  #
  # Public for test-coverage of the enrichment logic without booting a live
  # HTTP endpoint. Pass `opts: [skip_cleanup: true]` to short-circuit the
  # cleanup fan-out — useful in tests that don't want Req making real calls.
  def enrich_with_plugin_asserts(result, plugin_spec, opts) do
    response = %{
      status: result.status,
      body: Map.get(result, :body_text),
      headers: Map.get(result, :headers, []),
      duration_ms: Map.get(result, :duration_ms, 0)
    }

    asserts_results =
      Enum.map(Map.get(plugin_spec, :asserts, []) || [], fn assertion ->
        case Barkpark.ApiTestRunner.Asserts.evaluate(assertion, response) do
          {kind, msg} when kind in [:pass, :fail] ->
            %{assertion: assertion, status: kind, message: msg}
        end
      end)

    cleanup_results =
      if Keyword.get(opts, :skip_cleanup, false) do
        []
      else
        run_plugin_cleanup(Map.get(plugin_spec, :cleanup, []) || [], opts)
      end

    result
    |> Map.put(:plugin_asserts, asserts_results)
    |> Map.put(:plugin_cleanup, cleanup_results)
    |> Map.put(:plugin_status, compute_plugin_status(asserts_results))
  end

  # ── render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    endpoint = Endpoints.find(assigns.dataset, assigns.selected_id)
    form_state = Map.get(assigns.form_state_by_id, assigns.selected_id, %{})
    last_result = Map.get(assigns.last_result_by_id, assigns.selected_id)

    assigns =
      assigns
      |> assign(:endpoint, endpoint)
      |> assign(:form_state, form_state)
      |> assign(:last_result, last_result)

    ~H"""
    <.pane_layout id="api-tester-panes">
      <.pane_column title="API">
        <div class="pane-body">
            <%= for category <- @categories do %>
              <% collapsed = MapSet.member?(@collapsed_categories, category) %>
              <.pane_section_header
                collapsible
                collapsed={collapsed}
                phx_click="toggle-category"
                phx_value_category={category}
              >
                <.icon name={category_icon(category)} size={12} /> <%= category %>
              </.pane_section_header>
              <%= unless collapsed do %>
                <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
                  <.pane_item
                    id={"api-ep-#{ep.id}"}
                    phx_click="select"
                    phx_value_id={ep.id}
                    selected={@selected_id == ep.id}
                  >
                    <:icon><.icon name={endpoint_icon(ep)} size={16} /></:icon>
                    <%= ep.label %>
                    <:badge><%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %></:badge>
                  </.pane_item>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </.pane_column>

        <.pane_column title={docs_column_title(@endpoint)} marker_class="api-col-docs">
          <:header_actions>
            <%= if @endpoint && @endpoint.kind == :endpoint do %>
              <span class={"badge #{auth_badge_class(@endpoint.auth)}"}><%= @endpoint.auth %></span>
            <% end %>
          </:header_actions>
          <div class="api-col-body">
            <%= cond do %>
              <% @endpoint == nil -> %>
                <.pane_empty message="Select an endpoint on the left." />
              <% @endpoint.kind == :reference -> %>
                <%= render_reference(assigns, @endpoint.render_key) %>
              <% true -> %>
                <.endpoint_docs endpoint={@endpoint} />
                <.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} running={@running} />
            <% end %>
          </div>
        </.pane_column>

        <.pane_column title="Response" marker_class="api-col-response" last>
          <:header_actions>
            <%= if @scenario_results != [] do %>
              <div class="api-response-meta">
                <span class="badge badge-verdict-pass"><%= Enum.count(@scenario_results, &(&1.result.verdict == :pass)) %> pass</span>
                <span class="badge badge-verdict-fail"><%= Enum.count(@scenario_results, &(&1.result.verdict == :fail)) %> fail</span>
                <span class="badge badge-verdict-error"><%= Enum.count(@scenario_results, &(&1.result.verdict == :error)) %> error</span>
                <span class="badge badge-verdict-unverified"><%= Enum.count(@scenario_results, &(&1.result.verdict == :unverified)) %> unverified</span>
              </div>
            <% else %>
              <%= if @last_result do %>
                <div class="api-response-meta">
                  <%= render_verdict_badge(@last_result) %>
                  <span class="text-xs text-dim api-response-timing">HTTP <%= @last_result.status %> · <%= @last_result.duration_ms %>ms</span>
                </div>
              <% end %>
            <% end %>
          </:header_actions>
          <div class="api-col-body">
            <%= if @scenario_results != [] do %>
              <div class="scenario-results">
                <div class="scenario-scroll">
                  <%= for {category, cat_scenarios} <- @scenario_results |> Enum.group_by(& &1.category) |> Enum.sort_by(&elem(&1, 0)) do %>
                    <div class="scenario-cat-header">
                      <%= category %>
                    </div>
                    <%= for sr <- cat_scenarios do %>
                      <div class={["scenario-row", sr.result.verdict == :fail && "scenario-row--fail"]}>
                        <div>
                          <span class="scenario-endpoint"><%= sr.endpoint_label %></span>
                          <span class="scenario-label"><%= sr.label %></span>
                        </div>
                        <div class="scenario-verdict">
                          <span class="scenario-duration"><%= sr.result.duration_ms %>ms</span>
                          <span class={"badge #{verdict_badge_class(sr.result.verdict)}"}>
                            <%= if sr.result.verdict == :pass, do: "PASS", else: if(sr.result.verdict == :fail, do: "FAIL", else: "ERR") %>
                          </span>
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% else %>
              <%= if @last_result do %>
                <.response_view result={@last_result} />
              <% else %>
                <.pane_empty message="No response yet. Click Run." />
              <% end %>
            <% end %>
          </div>
        </.pane_column>
    </.pane_layout>

    <style>
      /* Full-height pane layout (48px = top nav bar from app.html.heex) */
      #api-tester-panes { height: calc(100vh - 48px); }
      /* Nav column inherits .pane-column's 260px default. Docs and response
         columns override width + min-width so they actually flex instead of
         staying pinned. These two rules are the whole reason pane_column no
         longer carries a :flex attr: the declarations below are byte-for-byte
         what that attr used to inline, but as classes they stay beatable by
         the width-bucket rules in root.html.heex (an inline style was not). */
      .api-col-docs { flex: 1.1; width: auto; min-width: 0; }
      .api-col-response { flex: 1; width: auto; min-width: 0; }
      .api-col-body { flex: 1; overflow-y: auto; padding: 20px 24px; }

      /* HTTP method pill — echoes shadcn badge shape */
      .api-method {
        display: inline-flex; align-items: center; height: 20px; padding: 0 7px;
        border-radius: 4px; font-size: 10px; font-weight: 700;
        font-family: var(--font-mono); letter-spacing: 0.04em;
      }
      .api-method-get { background: var(--primary-soft); color: var(--primary); }
      .api-method-post { background: var(--ok-soft); color: var(--success); }
      .api-url { font-family: var(--font-mono); font-size: 12px; font-weight: 500; color: var(--fg); }

      /* Section headings inside the docs column */
      .api-section {
        font-size: 11px; font-weight: 600; text-transform: uppercase;
        letter-spacing: 0.06em; color: var(--fg-dim);
        margin: 20px 0 8px;
      }
      .api-section:first-child { margin-top: 0; }
      .api-description { color: var(--fg-muted); font-size: 13px; margin: 0 0 4px; line-height: 1.55; }

      /* Param tables */
      .api-table { width: 100%; border-collapse: collapse; font-size: 12px; }
      .api-table th, .api-table td {
        padding: 8px 10px; text-align: left;
        border-bottom: 1px solid var(--border-muted); vertical-align: top;
      }
      .api-table th {
        color: var(--fg-dim); font-weight: 600; text-transform: uppercase;
        letter-spacing: 0.04em; font-size: 10px;
      }
      .api-table code, .api-inline-code {
        font-family: var(--font-mono); font-size: 11px;
        background: var(--bg-muted); padding: 1px 5px; border-radius: 3px;
        color: var(--fg);
      }

      /* Playground card */
      .api-playground {
        background: var(--bg-card); border: 1px solid var(--border-muted);
        border-radius: var(--radius); padding: 16px; margin: 4px 0 12px;
      }
      .api-param-row {
        display: flex; align-items: center; gap: 10px; margin-bottom: 10px;
      }
      .api-param-row:last-child { margin-bottom: 0; }
      .api-param-label {
        width: 140px; flex-shrink: 0;
        font-family: var(--font-mono); font-size: 11px; color: var(--fg-muted);
      }
      .api-param-row .form-input {
        height: 30px; padding: 0 10px; font-size: 12px;
      }
      .api-param-row select.form-input { height: 30px; padding-right: 30px; }

      .api-body-textarea {
        width: 100%; min-height: 160px; margin-top: 2px;
        font-family: var(--font-mono); font-size: 12px; line-height: 1.5;
        padding: 10px 12px;
      }

      .api-actions { display: flex; gap: 10px; margin-top: 12px; }

      /* Code / response displays */
      .api-code-block {
        background: var(--bg-card); border: 1px solid var(--border-muted);
        border-radius: var(--radius-sm); padding: 12px 14px;
        font-family: var(--font-mono); font-size: 12px; color: var(--fg);
        white-space: pre-wrap; word-break: break-all;
        max-height: 480px; overflow: auto; line-height: 1.5;
      }
      .api-curl-block { max-height: 140px; font-size: 11px; }

      /* Response column */
      .api-response-meta { display: flex; align-items: center; gap: 8px; }
      .api-response-timing { font-family: var(--font-mono); }
      .api-verdict-reason {
        font-size: 12px; color: var(--fg-muted);
        margin: 4px 0 12px; font-style: italic;
      }

      /* Verdict badges — reuse .badge, provide colours */
      .badge-verdict-pass { background: var(--ok-soft); color: var(--success); }
      .badge-verdict-fail { background: var(--danger-soft); color: var(--destructive); }
      .badge-verdict-error { background: var(--warn-soft); color: var(--warning); }
      .badge-verdict-unverified { background: var(--bg-muted); color: var(--fg-muted); }

      /* Slim the verdict badge when it sits in place of a chevron in a pane-item row */
      .pane-item .badge {
        height: 18px; padding: 0 6px; font-size: 10px; margin-left: auto;
      }
      .pane-item .badge::before { display: none; }

      .api-runnable-note {
        margin-top: 12px; padding: 10px 14px;
        background: var(--bg-muted); border: 1px solid var(--border-muted);
        border-radius: var(--radius-sm);
        font-size: 12px; color: var(--fg-muted); line-height: 1.5;
      }
      .api-runnable-note code {
        font-family: var(--font-mono); font-size: 11px;
        background: var(--bg); padding: 1px 5px; border-radius: 3px;
      }

      /* Plugin asserts panel — appears between verdict-reason and headers
         when the selected endpoint carries a :plugin_spec. */
      .api-tester-plugin-asserts { margin: 0 0 12px; }
      .api-tester-plugin-asserts .status-pass { color: var(--success); }
      .api-tester-plugin-asserts .status-fail { color: var(--destructive); }
      .api-tester-plugin-asserts ul { list-style: none; padding: 0; margin: 0; }
      .api-tester-plugin-asserts .assert-row {
        display: flex; gap: 8px; padding: 4px 0;
        font-family: var(--font-mono); font-size: 12px; align-items: baseline;
      }
      .api-tester-plugin-asserts .assert-row::before {
        flex-shrink: 0; width: 12px; text-align: center;
      }
      .api-tester-plugin-asserts .assert-row.assert-pass::before {
        content: "✓"; color: var(--success);
      }
      .api-tester-plugin-asserts .assert-row.assert-fail::before {
        content: "✗"; color: var(--destructive);
      }
      .api-tester-plugin-asserts .assert-tag { color: var(--fg); font-weight: 500; }
      .api-tester-plugin-asserts .assert-message { color: var(--fg-muted); }

      .api-tester-plugin-cleanup {
        margin: 0 0 16px; font-size: 12px; color: var(--fg-muted);
      }
      .api-tester-plugin-cleanup summary {
        cursor: pointer; padding: 4px 0; user-select: none;
      }
      .api-tester-plugin-cleanup ul {
        list-style: none; padding: 6px 0 0; margin: 0;
      }
      .api-tester-plugin-cleanup li {
        padding: 2px 0; font-family: var(--font-mono); font-size: 11px;
      }
    </style>
    """
  end

  defp render_verdict_badge(nil), do: ""

  defp render_verdict_badge(%{verdict: verdict}) do
    label =
      case verdict do
        :pass -> "Pass"
        :fail -> "Fail"
        :error -> "Error"
        :unverified -> "Unverified"
      end

    class = "badge badge-verdict-#{verdict}"
    assigns = %{label: label, class: class}

    ~H"""
    <span class={@class}><%= @label %></span>
    """
  end

  defp render_reference(assigns, :envelope) do
    ~H"""
    <p class="api-description">Every document is returned as a flat JSON object. Reserved keys are always present; user content adds additional flat fields. User content cannot override reserved keys — they are silently dropped on write.</p>

    <div class="api-section">Reserved keys</div>
    <table class="api-table">
      <thead><tr><th>Key</th><th>Type</th><th>Description</th></tr></thead>
      <tbody>
        <tr><td><code>_id</code></td><td class="text-dim text-xs">string</td><td class="text-muted">Full document id, including <code class="api-inline-code">drafts.</code> prefix when a draft</td></tr>
        <tr><td><code>_type</code></td><td class="text-dim text-xs">string</td><td class="text-muted">Document type (matches schema name)</td></tr>
        <tr><td><code>_rev</code></td><td class="text-dim text-xs">string</td><td class="text-muted">32-char hex; changes on every write</td></tr>
        <tr><td><code>_draft</code></td><td class="text-dim text-xs">boolean</td><td class="text-muted"><code class="api-inline-code">true</code> when <code class="api-inline-code">_id</code> starts with <code class="api-inline-code">drafts.</code></td></tr>
        <tr><td><code>_publishedId</code></td><td class="text-dim text-xs">string</td><td class="text-muted">Id with <code class="api-inline-code">drafts.</code> prefix stripped</td></tr>
        <tr><td><code>_createdAt</code></td><td class="text-dim text-xs">string</td><td class="text-muted">ISO 8601 UTC, <code class="api-inline-code">Z</code> suffix</td></tr>
        <tr><td><code>_updatedAt</code></td><td class="text-dim text-xs">string</td><td class="text-muted">ISO 8601 UTC, <code class="api-inline-code">Z</code> suffix</td></tr>
      </tbody>
    </table>

    <div class="api-section">Example</div>
    <pre class="api-code-block"><%= ~s({\n  "_id": "p1",\n  "_type": "post",\n  "_rev": "a3f8c2d1e9b04567f2a1c3e5d7890abc",\n  "_draft": false,\n  "_publishedId": "p1",\n  "_createdAt": "2026-04-12T09:11:20Z",\n  "_updatedAt": "2026-04-12T10:03:45Z",\n  "title": "Hello World",\n  "category": "Tech"\n}) %></pre>
    """
  end

  defp render_reference(assigns, :error_codes) do
    ~H"""
    <p class="api-description">
      All errors return <code class="api-inline-code"><%= ~s({"error": {"code": "...", "message": "..."}}) %></code>.
      For <code class="api-inline-code">validation_failed</code>, a <code class="api-inline-code">details</code> map of field-level errors is included.
    </p>

    <div class="api-section">All codes</div>
    <table class="api-table">
      <thead><tr><th>Code</th><th>HTTP</th><th>Meaning</th></tr></thead>
      <tbody>
        <tr><td><code>not_found</code></td><td class="text-dim">404</td><td class="text-muted">Document or schema not found</td></tr>
        <tr><td><code>unauthorized</code></td><td class="text-dim">401</td><td class="text-muted">Missing or invalid token</td></tr>
        <tr><td><code>forbidden</code></td><td class="text-dim">403</td><td class="text-muted">Token lacks required permission</td></tr>
        <tr><td><code>schema_unknown</code></td><td class="text-dim">404</td><td class="text-muted">No schema registered for this type</td></tr>
        <tr><td><code>rev_mismatch</code></td><td class="text-dim">409</td><td class="text-muted"><code class="api-inline-code">ifRevisionID</code> did not match current rev</td></tr>
        <tr><td><code>conflict</code></td><td class="text-dim">409</td><td class="text-muted">Document already exists (on <code class="api-inline-code">create</code>)</td></tr>
        <tr><td><code>malformed</code></td><td class="text-dim">400</td><td class="text-muted">Request body is malformed, missing required key (e.g., <code class="api-inline-code">mutations</code>), or missing required parameter (e.g., <code class="api-inline-code">q</code> for search)</td></tr>
        <tr><td><code>validation_failed</code></td><td class="text-dim">422</td><td class="text-muted">Document failed validation; <code class="api-inline-code">details</code> map contains per-field errors</td></tr>
        <tr><td><code>internal_error</code></td><td class="text-dim">500</td><td class="text-muted">Unexpected server error</td></tr>
      </tbody>
    </table>
    """
  end

  defp render_reference(assigns, :known_limitations) do
    ~H"""
    <p class="api-description">The v1 contract as shipped. Quirks listed here are known, not bugs — they may be addressed in future versions.</p>

    <div class="api-section">Query &amp; Search</div>
    <ul class="api-quirks-list">
      <li>Reference expansion is <strong>depth 1 only</strong>: a referenced doc's own reference fields stay as raw id strings.</li>
      <li>Search matches <strong>title only</strong> via case-insensitive ILIKE. Content field search is not yet supported.</li>
      <li>No full-text indexing (GIN/tsvector). Search performance degrades on very large datasets.</li>
    </ul>

    <div class="api-section">History &amp; Revisions</div>
    <ul class="api-quirks-list">
      <li>Revisions are only recorded for mutations <strong>after the history feature was deployed</strong>. Pre-existing documents have no revision history.</li>
      <li>Restore always creates/updates a <strong>draft</strong>. You must explicitly publish to make the restored content live.</li>
      <li>The <code class="api-inline-code">action</code> field on revisions reflects the underlying storage operation, not the API mutation. A <code class="api-inline-code">patch</code> that creates a new draft shows action <code class="api-inline-code">"create"</code>, not <code class="api-inline-code">"patch"</code>.</li>
    </ul>

    <div class="api-section">Export</div>
    <ul class="api-quirks-list">
      <li>Export streams all documents including drafts. There is no perspective filter on export — use the <code class="api-inline-code">type</code> param to narrow scope.</li>
      <li>NDJSON response is not valid JSON as a whole — each line is a separate JSON object.</li>
    </ul>

    <div class="api-section">Webhooks</div>
    <ul class="api-quirks-list">
      <li>Webhook delivery is <strong>fire-and-forget</strong> with no retry. Failed deliveries are logged but not retried.</li>
      <li>Delivery timeout is 10 seconds. Slow receivers will see timeouts logged as errors.</li>
      <li>HMAC signatures use SHA-256: <code class="api-inline-code"><%= "sha256={hex}" %></code> in the <code class="api-inline-code">X-Webhook-Signature</code> header.</li>
    </ul>

    <div class="api-section">General</div>
    <ul class="api-quirks-list">
      <li>All timestamps are UTC with <code class="api-inline-code">Z</code> suffix (ISO 8601). No timezone support.</li>
      <li>Rate limiting is configured but thresholds are not yet published. Expect <code class="api-inline-code">429</code> under heavy load.</li>
    </ul>
    <style>
      .api-quirks-list {
        list-style: disc; padding-left: 20px; margin: 0;
        font-size: 13px; color: var(--fg-muted); line-height: 1.7;
      }
      .api-quirks-list li { margin-bottom: 4px; }
    </style>
    """
  end

  # Phase 8 WI4 — live, data-driven schema browser. Iterates
  # `Content.list_schemas/1` so plugin schemas (e.g. book) auto-appear with
  # field shape, visibility badge, and an example query curl. v2 field
  # types (composite/arrayOf/codelist/localizedText) render as collapsed
  # JSON dumps per CLAUDE.md plugin-v2 (decision D12).
  defp render_reference(assigns, :schema_browser) do
    schemas = Barkpark.Content.list_schemas(assigns.dataset)
    {public, private} = Enum.split_with(schemas, &(&1.visibility == "public"))
    assigns = assign(assigns, public_schemas: public, private_schemas: private)

    ~H"""
    <p class="api-description">
      Every schema registered in this dataset, with field shape and an example
      query curl. Plugin-registered schemas (visibility: <code class="api-inline-code">private</code>)
      require a Bearer token on <code class="api-inline-code">/v1/data/query/*</code> — see Query → List documents.
    </p>

    <div class="api-section">Public schemas (<%= length(@public_schemas) %>)</div>
    <%= for s <- @public_schemas do %>
      <.schema_browser_card schema={s} dataset={@dataset} />
    <% end %>

    <div class="api-section">Private schemas (<%= length(@private_schemas) %>)</div>
    <%= for s <- @private_schemas do %>
      <.schema_browser_card schema={s} dataset={@dataset} />
    <% end %>
    """
  end

  attr :schema, :map, required: true
  attr :dataset, :string, required: true

  defp schema_browser_card(assigns) do
    ~H"""
    <details class="api-schema-card">
      <summary class="api-schema-summary">
        <code><%= @schema.name %></code>
        <span class="text-muted"><%= @schema.title %></span>
        <span class={"badge badge-" <> @schema.visibility}><%= @schema.visibility %></span>
        <span class="text-dim text-xs"><%= length(@schema.fields || []) %> fields</span>
      </summary>
      <table class="api-table api-schema-fields">
        <thead><tr><th>Name</th><th>Type</th><th>Title</th><th>Spec</th></tr></thead>
        <tbody>
          <%= for f <- @schema.fields || [] do %>
            <tr>
              <td><code><%= f["name"] %></code></td>
              <td class="text-dim text-xs"><%= f["type"] %></td>
              <td class="text-muted"><%= f["title"] %></td>
              <td>
                <%= if f["type"] in ["composite", "arrayOf", "codelist", "localizedText"] do %>
                  <details>
                    <summary class="text-xs text-muted">JSON</summary>
                    <pre class="api-code-block api-schema-json"><%= Jason.encode!(f, pretty: true) %></pre>
                  </details>
                <% else %>
                  <span class="text-dim">—</span>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <div class="api-section">Example</div>
      <pre class="api-code-block"><%= "GET /v1/data/query/#{@dataset}/#{@schema.name}" %><%= if @schema.visibility == "private", do: "\nAuthorization: Bearer <token>", else: "" %></pre>
    </details>
    """
  end

  # The runner deliberately targets the FLAT API regardless of which
  # scoped page hosts the tester (P2 originally prefixed the scope and
  # the first real "Run all" proved it wrong): the tester documents the
  # endpoint CONTRACT, and its example catalog is written for the flat
  # surface — through the scoped mirror, anonymous public reads 403
  # (scoped API pipelines are membership-gated; the anonymous-Default
  # allowance is browser-only by design) and flat-only endpoints
  # (/v1/meta, /v1/tasks, /api/*) 404. Flat paths are host-absolute and
  # valid from any page, and resolve to the same Default tenant the
  # examples seed. Scoped-mirror documentation belongs in the endpoint
  # docs (each scoped family notes its /w/... twin), not the runner base.
  defp runner_base(_socket), do: "http://localhost:4000"
end
