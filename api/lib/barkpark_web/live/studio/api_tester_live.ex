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

  alias Barkpark.ApiTester.{Endpoints, Runner}

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
       token: "barkpark-dev-token",
       form_state_by_id: form_state_by_id,
       last_result_by_id: %{},
       scenario_results: []
     )}
  end

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

    # Seed form state lazily if this is the first time selecting this endpoint
    form_state =
      Map.get_lazy(socket.assigns.form_state_by_id, id, fn ->
        initial_form_state(endpoint)
      end)

    new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, form_state)

    {:noreply,
     assign(socket, selected_id: id, form_state_by_id: new_form_state_by_id, scenario_results: [])}
  end

  def handle_event("form-change", params, socket) do
    id = socket.assigns.selected_id
    current = Map.get(socket.assigns.form_state_by_id, id, %{})
    # Merge new form params on top, keeping existing ones for fields not in this event
    updated = Map.merge(current, Map.drop(params, ["_target"]))
    new_form_state_by_id = Map.put(socket.assigns.form_state_by_id, id, updated)
    {:noreply, assign(socket, form_state_by_id: new_form_state_by_id)}
  end

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

  def handle_event("run", _, socket) do
    endpoint = Endpoints.find(socket.assigns.dataset, socket.assigns.selected_id)

    new_results =
      if endpoint.kind == :reference || endpoint[:runnable] == false do
        socket.assigns.last_result_by_id
      else
        form_state = Map.get(socket.assigns.form_state_by_id, endpoint.id, %{})

        req =
          Runner.build_request(endpoint, form_state, %{
            token: socket.assigns.token,
            base: "http://localhost:4000"
          })

        legacy = %{
          id: endpoint.id,
          method: req.method,
          path: String.replace_prefix(req.url, "http://localhost:4000", ""),
          headers: req.headers,
          body: decode_body(req.body_text),
          expect: endpoint[:expect]
        }

        result = Runner.run(legacy)
        Map.put(socket.assigns.last_result_by_id, endpoint.id, result)
      end

    {:noreply, assign(socket, last_result_by_id: new_results, scenario_results: [])}
  end

  def handle_event("run-all", _, socket) do
    config = %{token: socket.assigns.token, base: "http://localhost:4000"}

    scenario_results =
      socket.assigns.endpoints
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

    {:noreply,
     assign(socket, scenario_results: scenario_results, last_result_by_id: last_results)}
  end

  defp decode_body(nil), do: nil
  defp decode_body(""), do: nil

  defp decode_body(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp build_curl(%{kind: :reference}, _form_state, _token), do: ""

  defp build_curl(endpoint, form_state, token) do
    req =
      Runner.build_request(endpoint, form_state, %{token: token, base: "http://localhost:4000"})

    parts = ["curl -sS"]
    parts = if req.method == "GET", do: parts, else: parts ++ ["-X", req.method]

    header_parts = Enum.flat_map(req.headers, fn {k, v} -> ["-H", shell_escape("#{k}: #{v}")] end)

    parts = parts ++ header_parts

    parts =
      if is_binary(req.body_text) and req.body_text != "" do
        parts ++ ["-d", shell_escape(req.body_text)]
      else
        parts
      end

    parts = parts ++ [shell_escape(req.url)]

    Enum.join(parts, " ")
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
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

        <.pane_column title={docs_column_title(@endpoint)} flex="1.1">
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
                <.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} />
            <% end %>
          </div>
        </.pane_column>

        <.pane_column title="Response" flex="1" last>
          <:header_actions>
            <%= if @scenario_results != [] do %>
              <div class="api-response-meta">
                <span class="badge badge-verdict-pass"><%= Enum.count(@scenario_results, &(&1.result.verdict == :pass)) %> pass</span>
                <span class="badge badge-verdict-fail"><%= Enum.count(@scenario_results, &(&1.result.verdict == :fail)) %> fail</span>
                <span class="badge badge-verdict-error"><%= Enum.count(@scenario_results, &(&1.result.verdict == :error)) %> error</span>
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
                <div style="overflow-y: auto; max-height: calc(100vh - 140px);">
                  <%= for {category, cat_scenarios} <- @scenario_results |> Enum.group_by(& &1.category) |> Enum.sort_by(&elem(&1, 0)) do %>
                    <div style="padding: 4px 12px; font-weight: 600; font-size: 11px; text-transform: uppercase; color: var(--fg-dim); border-bottom: 1px solid var(--border-muted); background: var(--bg-muted);">
                      <%= category %>
                    </div>
                    <%= for sr <- cat_scenarios do %>
                      <div style={"padding: 6px 12px; border-bottom: 1px solid var(--border-muted); display: flex; justify-content: space-between; align-items: center; font-size: 13px; #{if sr.result.verdict == :fail, do: "background: hsl(0 62.8% 50.6% / 0.05);", else: ""}"}>
                        <div>
                          <span style="color: var(--fg-dim);"><%= sr.endpoint_label %></span>
                          <span style="margin-left: 6px;"><%= sr.label %></span>
                        </div>
                        <div style="display: flex; align-items: center; gap: 8px;">
                          <span style="font-size: 11px; color: var(--fg-dim); font-family: var(--font-mono);"><%= sr.result.duration_ms %>ms</span>
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
         staying pinned. */
      .api-col-docs {
        width: auto; min-width: 0; flex: 1.1 1 0;
      }
      .api-col-response {
        width: auto; min-width: 0; flex: 1 1 0; border-right: none;
      }
      .api-col-body { flex: 1; overflow-y: auto; padding: 20px 24px; }

      /* HTTP method pill — echoes shadcn badge shape */
      .api-method {
        display: inline-flex; align-items: center; height: 20px; padding: 0 7px;
        border-radius: 4px; font-size: 10px; font-weight: 700;
        font-family: var(--font-mono); letter-spacing: 0.04em;
      }
      .api-method-get { background: hsl(217.2 91.2% 59.8% / 0.14); color: var(--primary); }
      .api-method-post { background: hsl(142 71% 45% / 0.14); color: var(--success); }
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
      .badge-verdict-pass { background: hsl(142 71% 45% / 0.12); color: var(--success); }
      .badge-verdict-fail { background: hsl(0 62.8% 50.6% / 0.12); color: var(--destructive); }
      .badge-verdict-error { background: hsl(38 92% 50% / 0.12); color: var(--warning); }

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
    </style>
    """
  end

  defp docs_column_title(nil), do: "—"
  defp docs_column_title(%{kind: :reference, label: label}), do: label

  defp docs_column_title(%{kind: :endpoint, method: method, path_template: path}),
    do: "#{method} #{path}"

  # Auth level → existing design-system badge variant
  defp auth_badge_class(:public), do: "badge-public"
  defp auth_badge_class(:token), do: "badge-draft"
  defp auth_badge_class(:admin), do: "badge-active"
  defp auth_badge_class(_), do: "badge-active"

  # Icons for the left-pane nav, reusing the small set already in
  # BarkparkWeb.Icons so the API pane renders the same look as Structure.
  defp category_icon("Reference"), do: "file-text"
  defp category_icon("Query"), do: "layout-list"
  defp category_icon("Mutate"), do: "settings"
  defp category_icon("Real-time"), do: "compass"
  defp category_icon("Schemas"), do: "folder"
  defp category_icon("Export"), do: "file"
  defp category_icon("History"), do: "file-text"
  defp category_icon("Analytics"), do: "tag"
  defp category_icon("Webhooks"), do: "compass"
  defp category_icon(_), do: "file"

  # Per-endpoint icon. Uses only icons that exist in Icons.@icons;
  # unknown names fall back to "file" via the Icons component.
  defp endpoint_icon(%{id: "ref-envelope"}), do: "file-text"
  defp endpoint_icon(%{id: "ref-errors"}), do: "file"
  defp endpoint_icon(%{id: "ref-limits"}), do: "settings"
  defp endpoint_icon(%{id: "query-list"}), do: "layout-list"
  defp endpoint_icon(%{id: "query-single"}), do: "file"
  defp endpoint_icon(%{category: "Mutate"}), do: "settings"
  defp endpoint_icon(%{id: "listen-sse"}), do: "compass"
  defp endpoint_icon(%{id: "schemas-list"}), do: "layout-list"
  defp endpoint_icon(%{id: "schemas-show"}), do: "file-text"
  defp endpoint_icon(_), do: "file"

  attr :endpoint, :map, required: true

  defp endpoint_docs(assigns) do
    ~H"""
    <p class="api-description"><%= @endpoint.description %></p>

    <%= if @endpoint.path_params != [] do %>
      <div class="api-section">Path params</div>
      <table class="api-table">
        <thead><tr><th>Name</th><th>Type</th><th>Notes</th></tr></thead>
        <tbody>
          <%= for p <- @endpoint.path_params do %>
            <tr>
              <td><code><%= p.name %></code></td>
              <td class="text-dim text-xs"><%= p.type %></td>
              <td class="text-muted"><%= p[:notes] || "" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>

    <%= if @endpoint.query_params != [] do %>
      <div class="api-section">Query params</div>
      <table class="api-table">
        <thead><tr><th>Name</th><th>Default</th><th>Notes</th></tr></thead>
        <tbody>
          <%= for p <- @endpoint.query_params do %>
            <tr>
              <td><code><%= p.name %></code></td>
              <td><code><%= p.default %></code></td>
              <td class="text-muted"><%= p[:notes] || "" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>

    <div class="api-section">Response shape</div>
    <pre class="api-code-block"><%= @endpoint.response_shape %></pre>

    <%= if @endpoint.possible_errors != [] do %>
      <div class="api-section">Possible errors</div>
      <div class="api-error-chips">
        <%= for code <- @endpoint.possible_errors do %>
          <code class="api-inline-code"><%= code %></code>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :endpoint, :map, required: true
  attr :form_state, :map, required: true
  attr :token, :string, required: true

  defp endpoint_playground(assigns) do
    assigns =
      assign(assigns, :curl, build_curl(assigns.endpoint, assigns.form_state, assigns.token))

    ~H"""
    <div class="api-section">Playground</div>
    <form phx-change="form-change" class="api-playground">
      <%= for p <- @endpoint.path_params do %>
        <div class="api-param-row">
          <label class="api-param-label"><%= p.name %></label>
          <input type="text" name={p.name} class="form-input" value={Map.get(@form_state, p.name, to_string(p.default))} />
        </div>
      <% end %>

      <%= for p <- @endpoint.query_params do %>
        <div class="api-param-row">
          <label class="api-param-label"><%= p.name %></label>
          <%= if p.type == :select do %>
            <select name={p.name} class="form-input">
              <%= for opt <- p[:options] || [] do %>
                <option value={opt} selected={opt == Map.get(@form_state, p.name, to_string(p.default))}><%= opt %></option>
              <% end %>
            </select>
          <% else %>
            <input type="text" name={p.name} class="form-input" value={Map.get(@form_state, p.name, to_string(p.default))} />
          <% end %>
        </div>
      <% end %>

      <%= if @endpoint.method == "POST" do %>
        <div class="api-section" style="margin-top: 16px;">Request body (JSON)</div>
        <textarea name="_body_text" class="form-input api-body-textarea" spellcheck="false"><%= Map.get(@form_state, "_body_text", "") %></textarea>
      <% end %>
    </form>

    <div class="api-section">Copy as curl</div>
    <pre class="api-code-block api-curl-block" id="tester-curl"><%= @curl %></pre>

    <%= if @endpoint[:runnable] == false do %>
      <div class="api-runnable-note">
        Streaming endpoint — the playground does not support SSE. Use <code>curl -N</code>
        from the command line to tail this stream.
      </div>
    <% else %>
      <div class="api-actions">
        <button phx-click="run" class="btn btn-primary btn-sm">Run</button>
        <button
          type="button"
          onclick={~s|navigator.clipboard.writeText(document.getElementById('tester-curl').textContent); this.textContent='Copied \u2713'; setTimeout(() => this.textContent='Copy curl', 1500)|
          }
          class="btn btn-sm"
        >Copy curl</button>
      </div>
    <% end %>
    """
  end

  attr :result, :map, required: true

  defp response_view(assigns) do
    ~H"""
    <div class="api-verdict-reason"><%= @result.verdict_reason %></div>

    <div class="api-section">Response headers</div>
    <pre class="api-code-block"><%= Enum.map_join(@result.headers, "\n", fn {k, v} -> "#{k}: #{v}" end) %></pre>

    <div class="api-section">Response body</div>
    <pre class="api-code-block"><%= format_body(@result) %></pre>
    """
  end

  defp format_body(%{body_json: json}) when is_map(json) or is_list(json),
    do: Jason.encode!(json, pretty: true)

  defp format_body(%{body_text: text}) when is_binary(text) and text != "", do: text
  defp format_body(_), do: ""

  defp verdict_badge_class(:pass), do: "badge-verdict-pass"
  defp verdict_badge_class(:fail), do: "badge-verdict-fail"
  defp verdict_badge_class(_), do: "badge-verdict-error"

  defp render_verdict_badge(nil), do: ""

  defp render_verdict_badge(%{verdict: verdict}) do
    label =
      case verdict do
        :pass -> "Pass"
        :fail -> "Fail"
        :error -> "Error"
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
end
