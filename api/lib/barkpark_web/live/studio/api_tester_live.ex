defmodule BarkparkWeb.Studio.ApiTesterLive do
  @moduledoc """
  Studio pane: interactive v1 API contract tester.

  Left column: pre-canned test cases grouped by category, plus "Run all".
  Right column: request preview (editable body), Run button, and the full
  response (status, duration, headers, pretty JSON body) with a pass/fail
  badge driven by `Barkpark.ApiTester.Runner`'s predicate checks.

  Dispatch is server-side via :httpc — the requests hit the same Phoenix
  endpoint that is serving this LiveView, so network/TLS/CORS specifics
  are out of scope here. For browser-origin checks use the CORS section
  of the docs/api-v1.md reference.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.ApiTester.{Runner, TestCases}

  @impl true
  def mount(_params, _session, socket) do
    cases = TestCases.all()

    {:ok,
     assign(socket,
       cases: cases,
       categories: cases |> Enum.map(& &1.category) |> Enum.uniq(),
       selected_id: (List.first(cases) || %{id: nil}).id,
       custom_body: "",
       last_result: nil,
       running: false,
       results_by_id: %{}
     )}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    tc = TestCases.find(id)
    default_body = if tc && tc.body, do: Jason.encode!(tc.body, pretty: true), else: ""
    {:noreply, assign(socket, selected_id: id, custom_body: default_body, last_result: nil)}
  end

  def handle_event("body-edit", %{"custom_body" => body}, socket) do
    {:noreply, assign(socket, custom_body: body)}
  end

  def handle_event("run", _, socket) do
    tc = TestCases.find(socket.assigns.selected_id)

    result =
      cond do
        tc == nil ->
          %{verdict: :error, verdict_reason: "no test selected"}

        socket.assigns.custom_body == "" ->
          Runner.run(tc)

        true ->
          Runner.run(tc, body_override: socket.assigns.custom_body)
      end

    new_results = Map.put(socket.assigns.results_by_id, socket.assigns.selected_id, result)
    {:noreply, assign(socket, last_result: result, results_by_id: new_results)}
  end

  def handle_event("run-all", _, socket) do
    results =
      socket.assigns.cases
      |> Enum.reduce(%{}, fn tc, acc -> Map.put(acc, tc.id, Runner.run(tc)) end)

    {:noreply, assign(socket, results_by_id: results, last_result: results[socket.assigns.selected_id])}
  end

  # ── render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tester-wrapper">
      <div class="tester-body">
        <aside class="tester-sidebar">
          <%= for category <- @categories do %>
            <div class="tester-category-title"><%= category %></div>
            <%= for tc <- Enum.filter(@cases, &(&1.category == category)) do %>
              <button
                phx-click="select"
                phx-value-id={tc.id}
                class={"tester-case-row #{if @selected_id == tc.id, do: "is-selected"}"}
              >
                <span class="tester-case-row-label"><%= tc.label %></span>
                <%= render_verdict_badge(Map.get(@results_by_id, tc.id)) %>
              </button>
            <% end %>
          <% end %>
        </aside>

        <main class="tester-main">
          <div class="tester-main-header">
            <div class="tester-main-title">API Tester — /v1 contract</div>
            <button phx-click="run-all" class="tester-btn-primary">Run all</button>
          </div>

          <%= if tc = TestCases.find(@selected_id) do %>
            <div class="tester-case-header">
              <div>
                <div class="tester-case-method-row">
                  <span class={"tester-method tester-method-#{String.downcase(tc.method)}"}><%= tc.method %></span>
                  <span class="tester-url"><%= tc.path %></span>
                </div>
                <div class="tester-case-desc"><%= tc.description %></div>
              </div>
              <button phx-click="run" class="tester-btn-primary">Run</button>
            </div>

            <%= if tc.headers != [] do %>
              <div class="tester-section-title">Headers</div>
              <div class="tester-headers">
                <%= for {k, v} <- tc.headers do %>
                  <div class="tester-header-row">
                    <span class="tester-header-name"><%= k %></span>
                    <span class="tester-header-value"><%= mask_header(k, v) %></span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if tc.body do %>
              <div class="tester-section-title">Body (editable)</div>
              <form phx-change="body-edit">
                <textarea
                  name="custom_body"
                  class="tester-body-editor"
                  rows="8"
                  spellcheck="false"
                ><%= @custom_body %></textarea>
              </form>
            <% end %>

            <%= if @last_result do %>
              <div class="tester-divider"></div>
              <div class="tester-result-header">
                <div class="tester-result-title">Response</div>
                <div class="tester-result-meta">
                  <span class={"tester-badge tester-badge-#{@last_result.verdict}"}>
                    <%= @last_result.verdict |> to_string() |> String.upcase() %>
                  </span>
                  <span class="tester-status">HTTP <%= @last_result.status %></span>
                  <span class="tester-duration"><%= @last_result.duration_ms %>ms</span>
                </div>
              </div>

              <div class="tester-verdict-reason"><%= @last_result.verdict_reason %></div>

              <div class="tester-section-title">Response headers</div>
              <div class="tester-headers">
                <%= for {k, v} <- @last_result.headers do %>
                  <div class="tester-header-row">
                    <span class="tester-header-name"><%= k %></span>
                    <span class="tester-header-value"><%= v %></span>
                  </div>
                <% end %>
              </div>

              <div class="tester-section-title">Response body</div>
              <pre class="tester-body-view"><%= format_body(@last_result) %></pre>
            <% end %>
          <% else %>
            <div class="tester-empty">Select a test case on the left.</div>
          <% end %>
        </main>
      </div>
    </div>

    <style>
      .tester-wrapper { background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
      .tester-btn-primary { background: var(--primary); color: var(--primary-fg); border: none; padding: 6px 14px; border-radius: 4px; font-size: 13px; cursor: pointer; font-weight: 500; }
      .tester-btn-primary:hover { opacity: 0.9; }

      .tester-body { display: flex; min-height: calc(100vh - 60px); }
      .tester-main-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
      .tester-main-title { font-weight: 600; font-size: 16px; }

      .tester-sidebar { width: 300px; border-right: 1px solid var(--border); overflow-y: auto; padding: 8px 0; background: var(--bg-subtle); }
      .tester-category-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; padding: 12px 16px 6px; }
      .tester-case-row { display: flex; justify-content: space-between; align-items: center; width: 100%; background: none; border: none; text-align: left; padding: 8px 16px; font-size: 13px; color: var(--fg); cursor: pointer; gap: 8px; }
      .tester-case-row:hover { background: var(--bg-hover); }
      .tester-case-row.is-selected { background: var(--bg-active); color: var(--fg); font-weight: 500; }
      .tester-case-row-label { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

      .tester-main { flex: 1; overflow-y: auto; padding: 24px 32px; max-width: 1000px; }
      .tester-case-header { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 20px; }
      .tester-case-method-row { display: flex; align-items: center; gap: 10px; font-family: "SF Mono", ui-monospace, monospace; }
      .tester-method { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
      .tester-method-get { background: hsl(210 80% 90%); color: hsl(210 80% 30%); }
      .tester-method-post { background: hsl(140 60% 88%); color: hsl(140 60% 28%); }
      .tester-method-put, .tester-method-patch { background: hsl(40 80% 88%); color: hsl(40 80% 28%); }
      .tester-method-delete { background: hsl(0 80% 90%); color: hsl(0 80% 35%); }
      .tester-url { font-size: 13px; color: var(--fg); word-break: break-all; }
      .tester-case-desc { font-size: 12px; color: var(--fg-muted); margin-top: 6px; }

      .tester-section-title { font-size: 11px; font-weight: 600; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; margin: 18px 0 6px; }
      .tester-headers { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 8px 12px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; }
      .tester-header-row { display: flex; gap: 12px; padding: 2px 0; }
      .tester-header-name { color: var(--fg-muted); min-width: 160px; }
      .tester-header-value { color: var(--fg); word-break: break-all; }

      .tester-body-editor { width: 100%; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; background: var(--bg-subtle); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 10px; resize: vertical; }

      .tester-divider { height: 1px; background: var(--border); margin: 24px 0; }
      .tester-result-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
      .tester-result-title { font-weight: 600; font-size: 14px; }
      .tester-result-meta { display: flex; gap: 10px; align-items: center; font-size: 12px; }
      .tester-status { font-family: "SF Mono", ui-monospace, monospace; color: var(--fg-muted); }
      .tester-duration { color: var(--fg-muted); }
      .tester-badge { padding: 2px 10px; border-radius: 10px; font-size: 11px; font-weight: 700; letter-spacing: 0.3px; }
      .tester-badge-pass { background: hsl(140 60% 90%); color: hsl(140 70% 25%); }
      .tester-badge-fail { background: hsl(0 70% 92%); color: hsl(0 70% 35%); }
      .tester-badge-error { background: hsl(40 80% 90%); color: hsl(40 70% 30%); }
      .tester-verdict-reason { font-size: 12px; color: var(--fg-muted); margin-bottom: 8px; font-style: italic; }

      .tester-body-view { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 4px; padding: 12px 16px; font-family: "SF Mono", ui-monospace, monospace; font-size: 12px; color: var(--fg); white-space: pre-wrap; word-break: break-all; max-height: 400px; overflow: auto; }

      .tester-empty { color: var(--fg-muted); padding: 40px; text-align: center; }
    </style>
    """
  end

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

  defp format_body(%{body_json: json}) when is_map(json) or is_list(json) do
    Jason.encode!(json, pretty: true)
  end

  defp format_body(%{body_text: text}), do: text

  defp mask_header("Authorization", _), do: "Bearer *****"
  defp mask_header(_, v), do: v
end
