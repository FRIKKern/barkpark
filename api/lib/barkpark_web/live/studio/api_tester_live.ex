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

    {:ok,
     assign(socket,
       nav_section: :api_tester,
       dataset: dataset,
       endpoints: endpoints,
       categories: endpoints |> Enum.map(& &1.category) |> Enum.uniq(),
       selected_id: selected.id,
       token: "barkpark-dev-token",
       form_state_by_id: form_state_by_id,
       last_result_by_id: %{}
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

    {:noreply, assign(socket, selected_id: id, form_state_by_id: new_form_state_by_id)}
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

  def handle_event("run", _, socket) do
    endpoint = Endpoints.find(socket.assigns.dataset, socket.assigns.selected_id)

    new_results =
      if endpoint.kind == :reference do
        socket.assigns.last_result_by_id
      else
        form_state = Map.get(socket.assigns.form_state_by_id, endpoint.id, %{})
        req = Runner.build_request(endpoint, form_state, %{token: socket.assigns.token, base: "http://localhost:4000"})

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

    {:noreply, assign(socket, last_result_by_id: new_results)}
  end

  def handle_event("run-all", _, socket) do
    results =
      socket.assigns.endpoints
      |> Enum.filter(&(&1.kind == :endpoint && &1[:expect] != nil))
      |> Enum.reduce(%{}, fn ep, acc ->
        form_state = Map.get(socket.assigns.form_state_by_id, ep.id, initial_form_state(ep))
        req = Runner.build_request(ep, form_state, %{token: socket.assigns.token, base: "http://localhost:4000"})
        legacy = %{
          id: ep.id, method: req.method,
          path: String.replace_prefix(req.url, "http://localhost:4000", ""),
          headers: req.headers, body: decode_body(req.body_text), expect: ep.expect
        }
        Map.put(acc, ep.id, Runner.run(legacy))
      end)

    {:noreply, assign(socket, last_result_by_id: results)}
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
    req = Runner.build_request(endpoint, form_state, %{token: token, base: "http://localhost:4000"})

    parts = ["curl -sS"]
    parts = if req.method == "GET", do: parts, else: parts ++ ["-X", req.method]

    header_parts =
      Enum.flat_map(req.headers, fn {k, v} -> ["-H", shell_escape("#{k}: #{v}")] end)

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
    <div class="tester-wrapper">
      <div class="tester-topbar">
        <div class="tester-topbar-title">API Docs + Playground — /v1 contract</div>
        <form phx-change="token-change" class="tester-token-form">
          <label class="tester-token-label">Token</label>
          <input type="text" name="token" value={@token} class="tester-token-input" phx-debounce="300" />
        </form>
        <button phx-click="run-all" class="tester-btn-primary">Run all</button>
      </div>

      <div class="tester-body">
        <aside class="tester-sidebar">
          <%= for category <- @categories do %>
            <div class="tester-category-title"><%= category %></div>
            <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
              <button
                phx-click="select"
                phx-value-id={ep.id}
                class={"tester-case-row #{if @selected_id == ep.id, do: "is-selected"}"}
              >
                <span class="tester-case-row-label"><%= ep.label %></span>
                <%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %>
              </button>
            <% end %>
          <% end %>
        </aside>

        <section class="tester-docs">
          <%= cond do %>
            <% @endpoint == nil -> %>
              <div class="tester-empty">Select an endpoint on the left.</div>
            <% @endpoint.kind == :reference -> %>
              <%= render_reference(assigns, @endpoint.render_key) %>
            <% true -> %>
              <.endpoint_docs endpoint={@endpoint} />
              <.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} />
          <% end %>
        </section>

        <section class="tester-response">
          <%= if @last_result do %>
            <.response_view result={@last_result} />
          <% else %>
            <div class="tester-empty">No response yet. Click <strong>Run</strong>.</div>
          <% end %>
        </section>
      </div>
    </div>

    <style>
      .tester-wrapper { background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
      .tester-topbar { display: flex; gap: 16px; align-items: center; padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--bg-subtle); }
      .tester-topbar-title { font-weight: 600; font-size: 14px; flex: 1; }
      .tester-token-form { display: flex; gap: 6px; align-items: center; }
      .tester-token-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--fg-muted); font-weight: 600; }
      .tester-token-input { width: 260px; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: "SF Mono", ui-monospace, monospace; }
      .tester-btn-primary { background: var(--primary); color: var(--primary-fg); border: none; padding: 6px 14px; border-radius: 4px; font-size: 13px; cursor: pointer; font-weight: 500; }
      .tester-btn-primary:hover { opacity: 0.9; }

      .tester-body { display: grid; grid-template-columns: 260px 1fr 1fr; min-height: calc(100vh - 110px); }
      .tester-sidebar { border-right: 1px solid var(--border); overflow-y: auto; padding: 8px 0; background: var(--bg-subtle); }
      .tester-category-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; padding: 12px 16px 6px; }
      .tester-case-row { display: flex; justify-content: space-between; align-items: center; width: 100%; background: none; border: none; text-align: left; padding: 8px 16px; font-size: 13px; color: var(--fg); cursor: pointer; gap: 8px; }
      .tester-case-row:hover { background: var(--bg-hover); }
      .tester-case-row.is-selected { background: var(--bg-active); color: var(--fg); font-weight: 500; }
      .tester-case-row-label { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

      .tester-docs { border-right: 1px solid var(--border); padding: 24px 32px; overflow-y: auto; }
      .tester-response { padding: 24px 32px; overflow-y: auto; }

      .tester-method-row { display: flex; align-items: center; gap: 10px; font-family: "SF Mono", ui-monospace, monospace; margin-bottom: 10px; }
      .tester-method { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
      .tester-method-get { background: hsl(210 80% 90%); color: hsl(210 80% 30%); }
      .tester-method-post { background: hsl(140 60% 88%); color: hsl(140 60% 28%); }
      .tester-url { font-size: 13px; color: var(--fg); word-break: break-all; }
      .tester-auth-badge { display: inline-block; padding: 2px 8px; font-size: 10px; border-radius: 999px; letter-spacing: 0.4px; font-weight: 600; text-transform: uppercase; }
      .tester-auth-public { background: hsl(140 60% 90%); color: hsl(140 70% 28%); }
      .tester-auth-token { background: hsl(40 80% 88%); color: hsl(40 80% 30%); }
      .tester-auth-admin { background: hsl(280 60% 90%); color: hsl(280 60% 35%); }

      .tester-section-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; margin: 18px 0 8px; }

      .tester-param-table { width: 100%; border-collapse: collapse; font-size: 12px; }
      .tester-param-table th, .tester-param-table td { padding: 6px 8px; text-align: left; border-bottom: 1px solid var(--border); vertical-align: top; }
      .tester-param-table th { color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.4px; font-size: 10px; }
      .tester-param-table code { font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; }

      .tester-playground { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 6px; padding: 14px 16px; margin: 16px 0; }
      .tester-playground-row { display: flex; gap: 8px; margin-bottom: 8px; align-items: center; }
      .tester-playground-row label { width: 140px; font-size: 11px; color: var(--fg-muted); font-family: "SF Mono", ui-monospace, monospace; }
      .tester-playground-row input, .tester-playground-row select { flex: 1; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: inherit; }
      .tester-playground-body { width: 100%; min-height: 160px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 8px; resize: vertical; margin-top: 6px; box-sizing: border-box; }
      .tester-playground-actions { display: flex; gap: 10px; margin-top: 12px; }

      .tester-response-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
      .tester-badge { padding: 2px 10px; border-radius: 10px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
      .tester-badge-pass { background: hsl(140 60% 90%); color: hsl(140 70% 25%); }
      .tester-badge-fail { background: hsl(0 70% 92%); color: hsl(0 70% 35%); }
      .tester-badge-error { background: hsl(40 80% 90%); color: hsl(40 70% 30%); }

      .tester-json-pre, .tester-shape-pre { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 10px 14px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; color: var(--fg); white-space: pre-wrap; word-break: break-all; max-height: 500px; overflow: auto; }

      .tester-ref-table { width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 10px; }
      .tester-ref-table th, .tester-ref-table td { padding: 6px 10px; text-align: left; border-bottom: 1px solid var(--border); }
      .tester-ref-table th { font-size: 10px; text-transform: uppercase; color: var(--fg-muted); }
      .tester-ref-table code { font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; background: var(--bg-subtle); padding: 1px 4px; border-radius: 3px; }

      .tester-empty { color: var(--fg-muted); padding: 40px; text-align: center; }
      .tester-curl-pre { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 10px 14px; font-family: "SF Mono", ui-monospace, monospace; font-size: 11px; color: var(--fg); white-space: pre-wrap; word-break: break-all; margin-top: 4px; max-height: 140px; overflow: auto; }
      .tester-btn-secondary { background: var(--bg); color: var(--fg); border: 1px solid var(--border); padding: 6px 14px; border-radius: 4px; font-size: 13px; cursor: pointer; font-weight: 500; font-family: inherit; }
      .tester-btn-secondary:hover { background: var(--bg-hover); }
    </style>
    """
  end

  attr :endpoint, :map, required: true
  defp endpoint_docs(assigns) do
    ~H"""
    <div class="tester-method-row">
      <span class={"tester-method tester-method-#{String.downcase(@endpoint.method)}"}>
        <%= @endpoint.method %>
      </span>
      <span class="tester-url"><%= @endpoint.path_template %></span>
      <span class={"tester-auth-badge tester-auth-#{@endpoint.auth}"}><%= @endpoint.auth %></span>
    </div>

    <p><%= @endpoint.description %></p>

    <%= if @endpoint.path_params != [] do %>
      <div class="tester-section-title">Path params</div>
      <table class="tester-param-table">
        <thead><tr><th>Name</th><th>Type</th><th>Notes</th></tr></thead>
        <tbody>
          <%= for p <- @endpoint.path_params do %>
            <tr><td><code><%= p.name %></code></td><td><%= p.type %></td><td><%= p[:notes] || "" %></td></tr>
          <% end %>
        </tbody>
      </table>
    <% end %>

    <%= if @endpoint.query_params != [] do %>
      <div class="tester-section-title">Query params</div>
      <table class="tester-param-table">
        <thead><tr><th>Name</th><th>Default</th><th>Notes</th></tr></thead>
        <tbody>
          <%= for p <- @endpoint.query_params do %>
            <tr>
              <td><code><%= p.name %></code></td>
              <td><code><%= p.default %></code></td>
              <td><%= p[:notes] || "" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>

    <div class="tester-section-title">Response shape</div>
    <pre class="tester-shape-pre"><%= @endpoint.response_shape %></pre>

    <%= if @endpoint.possible_errors != [] do %>
      <div class="tester-section-title">Possible errors</div>
      <ul>
        <%= for code <- @endpoint.possible_errors do %>
          <li><code><%= code %></code></li>
        <% end %>
      </ul>
    <% end %>
    """
  end

  attr :endpoint, :map, required: true
  attr :form_state, :map, required: true
  attr :token, :string, required: true
  defp endpoint_playground(assigns) do
    assigns = assign(assigns, :curl, build_curl(assigns.endpoint, assigns.form_state, assigns.token))

    ~H"""
    <div class="tester-section-title">Playground</div>
    <form phx-change="form-change" class="tester-playground">
      <%= for p <- @endpoint.path_params do %>
        <div class="tester-playground-row">
          <label><%= p.name %></label>
          <input type="text" name={p.name} value={Map.get(@form_state, p.name, to_string(p.default))} />
        </div>
      <% end %>

      <%= for p <- @endpoint.query_params do %>
        <div class="tester-playground-row">
          <label><%= p.name %></label>
          <%= if p.type == :select do %>
            <select name={p.name}>
              <%= for opt <- p[:options] || [] do %>
                <option value={opt} selected={opt == Map.get(@form_state, p.name, to_string(p.default))}><%= opt %></option>
              <% end %>
            </select>
          <% else %>
            <input type="text" name={p.name} value={Map.get(@form_state, p.name, to_string(p.default))} />
          <% end %>
        </div>
      <% end %>

      <%= if @endpoint.method == "POST" do %>
        <div class="tester-section-title">Request body (JSON)</div>
        <textarea name="_body_text" class="tester-playground-body" spellcheck="false"><%= Map.get(@form_state, "_body_text", "") %></textarea>
      <% end %>
    </form>

    <div class="tester-section-title">Copy as curl</div>
    <pre class="tester-curl-pre" id="tester-curl"><%= @curl %></pre>

    <div class="tester-playground-actions">
      <button phx-click="run" class="tester-btn-primary">Run</button>
      <button
        type="button"
        onclick={~s|navigator.clipboard.writeText(document.getElementById('tester-curl').textContent); this.textContent='Copied \u2713'; setTimeout(() => this.textContent='Copy curl', 1500)|
        }
        class="tester-btn-secondary"
      >Copy curl</button>
    </div>
    """
  end

  attr :result, :map, required: true
  defp response_view(assigns) do
    ~H"""
    <div class="tester-response-head">
      <div class="tester-section-title" style="margin: 0;">Response</div>
      <div>
        <span class={"tester-badge tester-badge-#{@result.verdict}"}>
          <%= @result.verdict |> to_string() |> String.upcase() %>
        </span>
        HTTP <%= @result.status %> • <%= @result.duration_ms %>ms
      </div>
    </div>
    <div style="font-size: 11px; color: var(--fg-muted); margin-bottom: 8px; font-style: italic;">
      <%= @result.verdict_reason %>
    </div>

    <div class="tester-section-title">Response headers</div>
    <div class="tester-json-pre"><%= Enum.map_join(@result.headers, "\n", fn {k, v} -> "#{k}: #{v}" end) %></div>

    <div class="tester-section-title">Response body</div>
    <pre class="tester-json-pre"><%= format_body(@result) %></pre>
    """
  end

  defp format_body(%{body_json: json}) when is_map(json) or is_list(json), do: Jason.encode!(json, pretty: true)
  defp format_body(%{body_text: text}) when is_binary(text) and text != "", do: text
  defp format_body(_), do: ""

  defp render_verdict_badge(nil), do: ""

  defp render_verdict_badge(%{verdict: verdict}) do
    symbol =
      case verdict do
        :pass -> "✓"
        :fail -> "✗"
        :error -> "!"
      end

    class = "tester-badge tester-badge-#{verdict}"
    assigns = %{symbol: symbol, class: class}

    ~H"""
    <span class={@class}><%= @symbol %></span>
    """
  end

  defp render_reference(assigns, :envelope) do
    ~H"""
    <div class="tester-method-row">
      <span class="tester-url" style="font-weight: 600;">Document Envelope</span>
    </div>
    <p>Every document is returned as a flat JSON object. Reserved keys are always present; user content adds additional flat fields. User content cannot override reserved keys — they are silently dropped on write.</p>

    <div class="tester-section-title">Reserved keys</div>
    <table class="tester-ref-table">
      <thead><tr><th>Key</th><th>Type</th><th>Description</th></tr></thead>
      <tbody>
        <tr><td><code>_id</code></td><td>string</td><td>Full document id, including <code>drafts.</code> prefix when a draft</td></tr>
        <tr><td><code>_type</code></td><td>string</td><td>Document type (matches schema name)</td></tr>
        <tr><td><code>_rev</code></td><td>string</td><td>32-char hex; changes on every write</td></tr>
        <tr><td><code>_draft</code></td><td>boolean</td><td><code>true</code> when <code>_id</code> starts with <code>drafts.</code></td></tr>
        <tr><td><code>_publishedId</code></td><td>string</td><td>Id with <code>drafts.</code> prefix stripped</td></tr>
        <tr><td><code>_createdAt</code></td><td>string</td><td>ISO 8601 UTC, <code>Z</code> suffix</td></tr>
        <tr><td><code>_updatedAt</code></td><td>string</td><td>ISO 8601 UTC, <code>Z</code> suffix</td></tr>
      </tbody>
    </table>

    <div class="tester-section-title">Example</div>
    <pre class="tester-shape-pre"><%= ~s({\n  "_id": "p1",\n  "_type": "post",\n  "_rev": "a3f8c2d1e9b04567f2a1c3e5d7890abc",\n  "_draft": false,\n  "_publishedId": "p1",\n  "_createdAt": "2026-04-12T09:11:20Z",\n  "_updatedAt": "2026-04-12T10:03:45Z",\n  "title": "Hello World",\n  "category": "Tech"\n}) %></pre>
    """
  end

  defp render_reference(assigns, :error_codes) do
    ~H"""
    <div class="tester-method-row">
      <span class="tester-url" style="font-weight: 600;">Error Codes</span>
    </div>
    <p>All errors return <code><%= ~s({"error": {"code": "...", "message": "..."}}) %></code>. For <code>validation_failed</code>, a <code>details</code> map of field-level errors is included.</p>

    <table class="tester-ref-table">
      <thead><tr><th>Code</th><th>HTTP</th><th>Meaning</th></tr></thead>
      <tbody>
        <tr><td><code>not_found</code></td><td>404</td><td>Document or schema not found</td></tr>
        <tr><td><code>unauthorized</code></td><td>401</td><td>Missing or invalid token</td></tr>
        <tr><td><code>forbidden</code></td><td>403</td><td>Token lacks required permission</td></tr>
        <tr><td><code>schema_unknown</code></td><td>404</td><td>No schema registered for this type</td></tr>
        <tr><td><code>rev_mismatch</code></td><td>409</td><td><code>ifRevisionID</code> did not match current rev</td></tr>
        <tr><td><code>conflict</code></td><td>409</td><td>Document already exists (on <code>create</code>)</td></tr>
        <tr><td><code>malformed</code></td><td>400</td><td>Request body is malformed or missing <code>mutations</code> key</td></tr>
        <tr><td><code>validation_failed</code></td><td>422</td><td>Document failed validation; <code>details</code> map contains per-field errors</td></tr>
        <tr><td><code>internal_error</code></td><td>500</td><td>Unexpected server error</td></tr>
      </tbody>
    </table>
    """
  end

  defp render_reference(assigns, :known_limitations) do
    ~H"""
    <div class="tester-method-row">
      <span class="tester-url" style="font-weight: 600;">Known Limitations (v1.0)</span>
    </div>
    <p>Quirks of the v1 contract you should be aware of when building clients:</p>

    <ul>
      <li>Reference expansion (<code>?expand=</code>) is not implemented.</li>
      <li>Filter only supports exact-match on single values.</li>
      <li><code>previousRev</code> in SSE events is always <code>null</code>; full rev history lives in a separate revisions table that is not part of the v1 HTTP contract.</li>
      <li>Draft/published merging (<code>perspective=drafts</code>) happens after <code>LIMIT</code>/<code>OFFSET</code>, so a page can return fewer than <code>limit</code> rows.</li>
      <li>PubSub broadcasts fire even when a mutation transaction rolls back; the persistent events table is consistent, but the SSE stream may emit ghost events.</li>
      <li>Rate limiting is not enforced at the HTTP layer.</li>
    </ul>
    """
  end
end
