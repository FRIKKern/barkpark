defmodule BarkparkWeb.Studio.ApiTesterLive.Components do
  @moduledoc "Function components for the API-tester LiveView — docs, playground, and response panes, extracted from the view shell."
  use Phoenix.Component

  import BarkparkWeb.Studio.ApiTesterLive.Format
  import BarkparkWeb.Studio.ApiTesterLive.Request

  attr :endpoint, :map, required: true

  def endpoint_docs(assigns) do
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
  attr :running, :boolean, default: false

  def endpoint_playground(assigns) do
    assigns =
      assign(
        assigns,
        :curl,
        build_curl(
          assigns.endpoint,
          assigns.form_state,
          assigns.token,
          # Flat on purpose — see runner_base/1.
          "http://localhost:4000"
        )
      )

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
        <button phx-click="run" class="btn btn-primary btn-sm" disabled={@running}><%= if @running, do: "Running…", else: "Run" %></button>
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

  def response_view(assigns) do
    ~H"""
    <div class="api-verdict-reason"><%= @result.verdict_reason %></div>

    <%= if asserts = Map.get(@result, :plugin_asserts) do %>
      <% pass_count = Enum.count(asserts, &(&1.status == :pass)) %>
      <% total = length(asserts) %>
      <div class="api-tester-plugin-asserts">
        <div class="api-section" style="margin-top: 0;">
          Asserts —
          <span class={"status-#{Map.get(@result, :plugin_status, :pass)}"}>
            <%= pass_count %>/<%= total %> pass
          </span>
        </div>
        <ul>
          <%= for a <- asserts do %>
            <li class={"assert-row assert-#{a.status}"}>
              <span class="assert-tag"><%= format_assertion(a.assertion) %></span>
              <span class="assert-message"><%= a.message %></span>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <%= if (cleanup = Map.get(@result, :plugin_cleanup)) && cleanup != [] do %>
      <details class="api-tester-plugin-cleanup">
        <summary>Cleanup ran <%= length(cleanup) %> step<%= if length(cleanup) == 1, do: "", else: "s" %></summary>
        <ul>
          <%= for step <- cleanup do %>
            <li>
              <%= step.method %> <%= step.path %>
              → <%= step[:status] || "ERROR: #{step[:error]}" %>
              <%= if step[:duration_ms] do %>(<%= step.duration_ms %>ms)<% end %>
            </li>
          <% end %>
        </ul>
      </details>
    <% end %>

    <div class="api-section">Response headers</div>
    <pre class="api-code-block"><%= Enum.map_join(@result.headers, "\n", fn {k, v} -> "#{k}: #{v}" end) %></pre>

    <div class="api-section">Response body</div>
    <pre class="api-code-block"><%= format_body(@result) %></pre>
    """
  end
end
