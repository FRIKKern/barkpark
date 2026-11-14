defmodule BarkparkWeb.Studio.SearchLive.View do
  @moduledoc """
  Markup for the Studio Search page (`BarkparkWeb.Studio.SearchLive`).

  Draws only from the Studio's own classes (`.card`, `.btn`, `.form-input`,
  `.badge`) and design tokens, so it follows the light and dark themes with
  no styles of its own beyond layout.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import BarkparkWeb.StudioComponents.Controls

  alias BarkparkWeb.Studio.StudioLive.Paths
  alias Phoenix.LiveView.JS

  @cell "padding: 8px 12px 8px 0; border-bottom: 1px solid var(--border); text-align: left; vertical-align: middle;"
  @head @cell <> " color: var(--fg-muted); font-weight: 500;"
  @num @cell <> " text-align: right; font-variant-numeric: tabular-nums;"
  @num_head @head <> " text-align: right;"

  attr :scope_prefix, :string, required: true
  attr :dataset, :string, required: true
  attr :surface, :string, required: true
  attr :period, :string, required: true
  attr :insights, :map, required: true
  attr :synonyms, :list, required: true
  attr :rule, :map, required: true
  attr :preview, :map, default: nil
  attr :rule_error, :string, default: nil

  def page(assigns) do
    assigns =
      assign(assigns,
        cell: @cell,
        head: @head,
        num: @num,
        num_head: @num_head,
        top: top_queries(assigns.insights),
        zero: zero_hit_queries(assigns.insights),
        candidates: candidates(assigns.insights)
      )

    ~H"""
      <div
        class="search-live"
        style="max-width: 880px; margin: 32px auto; padding: 0 24px; font-family: var(--font);"
      >
        <h1 class="h1" style="margin-bottom: 4px;">{gettext("Search")}</h1>
        <p style="color: var(--fg-muted); margin-top: 0;">
          {gettext("What people searched for in %{dataset}, and the synonyms that help them find it.",
            dataset: @dataset
          )}
        </p>

        <nav
          aria-label={gettext("Search surface")}
          style="display: flex; gap: 8px; margin: 16px 0 24px;"
        >
          <.link
            :for={{surface, label} <- surfaces()}
            patch={path(@scope_prefix, @dataset, surface, @period)}
            class={["btn btn-sm", surface == @surface && "btn-primary"]}
            aria-current={surface == @surface && "page"}
            data-test-id={"search-surface-#{surface}"}
          >
            {label}
          </.link>
        </nav>

        <.bp_card aria-labelledby="search-insights-heading" data-test-id="search-insights">
          <.bp_section_header id="search-insights-heading" title={gettext("Insights")}>
            {period_range(@period, @insights)}. {gettext(
              "The numbers cover finished days, weeks and months. Today's searches show up tomorrow."
            )}
          </.bp_section_header>

          <div
            role="group"
            aria-label={gettext("Period")}
            style="display: flex; gap: 8px; margin-bottom: 20px;"
          >
            <.link
              :for={{period, label} <- periods()}
              patch={path(@scope_prefix, @dataset, @surface, period)}
              class={["btn btn-sm", period == @period && "btn-primary"]}
              aria-current={period == @period && "true"}
              data-test-id={"search-period-#{period}"}
            >
              {label}
            </.link>
          </div>

          <p
            :if={@top == []}
            role="status"
            data-test-id="search-insights-empty"
            style="color: var(--fg-muted); margin: 0;"
          >
            {gettext("No searches were recorded in this period.")}
          </p>

          <div :if={@top != []}>
            <dl style="display: flex; flex-wrap: wrap; gap: 12px 40px; margin: 0 0 24px;">
                  <.stat label={gettext("Found nothing")} value={percent(@insights.zeroHitRate)} />
              <.stat
                label={gettext("Found by a wider search")}
                value={percent(@insights.recoveryRate)}
              />
            </dl>

            <h3 class="h3" style="margin: 0 0 8px;">{gettext("Top searches")}</h3>
            <table
              class="text-sm"
              style="width: 100%; border-collapse: collapse; margin-bottom: 24px;"
              data-test-id="search-top-queries"
            >
              <thead>
                <tr>
                  <th scope="col" style={@head}>{gettext("Search")}</th>
                  <th scope="col" style={@num_head}>{gettext("Times")}</th>
                  <th scope="col" style={@num_head}>{gettext("Trend")}</th>
                  <th scope="col" style={@num_head}>{gettext("Found nothing")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={q <- @top}>
                  <td style={@cell}>{q.query}</td>
                  <td style={@num}>{q.searchCount}</td>
                  <td style={@num} title={gettext("Compared with the period before")}>
                    {delta(q.searchCountDelta)}
                  </td>
                  <td style={@num}>{q.zeroHitCount}</td>
                </tr>
              </tbody>
            </table>

            <h3 class="h3" style="margin: 0 0 4px;">{gettext("Searches that found nothing")}</h3>
            <p :if={@zero == []} style="color: var(--fg-muted); margin: 0;">
              {gettext("Every top search found something.")}
            </p>
            <ul
              :if={@zero != []}
              class="text-sm"
              style="list-style: none; margin: 0; padding: 0;"
              data-test-id="search-zero-hits"
            >
              <li
                :for={q <- @zero}
                style="display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--border);"
              >
                <span>
                  <strong>{q.query}</strong>
                  <span style="color: var(--fg-muted); margin-left: 8px;">
                    {ngettext(
                      "%{count} search found nothing",
                      "%{count} searches found nothing",
                      q.zeroHitCount
                    )}
                  </span>
                </span>
                <button
                  type="button"
                  class="btn btn-sm"
                  phx-click={
                    JS.push("rule_prefill", value: %{from: q.query})
                    |> JS.focus(to: "#search-rule-to")
                  }
                >
                  {gettext("Add a synonym")}
                </button>
              </li>
            </ul>
          </div>

          <div :if={@candidates != []} style="margin-top: 24px;">
            <h3 class="h3" style="margin: 0 0 4px;">{gettext("Suggested synonyms")}</h3>
            <p class="text-sm" style="color: var(--fg-muted); margin: 0 0 4px;">
              {gettext("People searched for the first word, found nothing, then found results with the second.")}
            </p>
            <ul
              class="text-sm"
              style="list-style: none; margin: 0; padding: 0;"
              data-test-id="search-candidates"
            >
              <li
                :for={c <- @candidates}
                style="display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--border);"
              >
                <span>
                  <strong>{c.from}</strong>
                  <span aria-hidden="true">→</span>
                  <span class="sr-only">{gettext("also finds")}</span>
                  <strong>{c.to}</strong>
                </span>
                <button
                  type="button"
                  class="btn btn-sm"
                  phx-click="rule_promote"
                  phx-value-from={c.from}
                  phx-value-to={c.to}
                >
                  {gettext("Add")}
                </button>
              </li>
            </ul>
          </div>
        </.bp_card>

        <.bp_card aria-labelledby="search-synonyms-heading" data-test-id="search-synonyms">
          <.bp_section_header id="search-synonyms-heading" title={gettext("Synonyms")}>
            {gettext("A synonym makes a search for one word also find another.")}
          </.bp_section_header>

          <p
            :if={@synonyms == []}
            role="status"
            data-test-id="search-synonyms-empty"
            style="color: var(--fg-muted); margin: 0 0 20px;"
          >
            {gettext("No synonyms yet.")}
          </p>

          <table
            :if={@synonyms != []}
            class="text-sm"
            style="width: 100%; border-collapse: collapse; margin-bottom: 24px;"
            data-test-id="search-synonym-list"
          >
            <thead>
              <tr>
                <th scope="col" style={@head}>{gettext("A search for")}</th>
                <th scope="col" style={@head}>{gettext("Also finds")}</th>
                <th scope="col" style={@head}>{gettext("Direction")}</th>
                <th scope="col" style={@num_head}>
                  <span class="sr-only">{gettext("Actions")}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @synonyms} data-test-id="search-synonym-row">
                <td style={@cell}>{s.from}</td>
                <td style={@cell}>{s.to}</td>
                <td style={@cell}>
                  {kind_label(s.kind)}
                  <span :if={s.source == "auto"} class="badge badge-muted" style="margin-left: 6px;">
                    {gettext("suggested")}
                  </span>
                </td>
                <td style={@num}>
                  <button
                    type="button"
                    class="btn btn-sm btn-destructive"
                    phx-click="rule_delete"
                    phx-value-id={s.id}
                    data-confirm={
                      gettext("Delete the synonym %{from} to %{to}?", from: s.from, to: s.to)
                    }
                    aria-label={
                      gettext("Delete the synonym %{from} to %{to}", from: s.from, to: s.to)
                    }
                  >
                    {gettext("Delete")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <h3 class="h3" style="margin: 0 0 12px;">{gettext("Add a synonym")}</h3>
          <form id="search-rule-form" phx-change="rule_change" phx-submit="rule_save">
            <.bp_field_row label={gettext("A search for")} for="search-rule-from" required>
              <.bp_input
                id="search-rule-from"
                name="rule[from]"
                value={@rule["from"]}
                autocomplete="off"
              />
            </.bp_field_row>
            <.bp_field_row label={gettext("Also finds")} for="search-rule-to" required>
              <.bp_input id="search-rule-to" name="rule[to]" value={@rule["to"]} autocomplete="off" />
            </.bp_field_row>
            <.bp_field_row label={gettext("Direction")} for="search-rule-kind">
              <.bp_select
                id="search-rule-kind"
                name="rule[kind]"
                value={@rule["kind"]}
                options={kinds()}
              />
            </.bp_field_row>

            <p
              :if={@preview}
              role="status"
              data-test-id="search-rule-preview"
              class="text-sm"
              style="margin: 0 0 12px;"
            >
              {gettext("“%{from}” finds %{before} now. “%{to}” finds %{after}.",
                from: @preview.from,
                before: @preview.beforeCount,
                to: @preview.to,
                after: @preview.afterCount
              )}
            </p>
            <p
              :if={@rule_error}
              role="alert"
              data-test-id="search-rule-error"
              class="text-sm"
              style="color: var(--destructive); margin: 0 0 12px;"
            >
              {@rule_error}
            </p>

            <div style="display: flex; gap: 8px;">
              <button type="submit" class="btn btn-primary">{gettext("Save synonym")}</button>
              <button type="button" class="btn" phx-click="rule_preview">
                {gettext("Show what it finds")}
              </button>
            </div>
          </form>
        </.bp_card>
      </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <dt class="text-sm" style="color: var(--fg-muted);">{@label}</dt>
      <dd class="h2" style="margin: 2px 0 0; font-variant-numeric: tabular-nums;">{@value}</dd>
    </div>
    """
  end

  defp surfaces, do: [{"documents", gettext("Documents")}, {"media", gettext("Media")}]

  defp periods,
    do: [
      {"day", gettext("Yesterday")},
      {"week", gettext("Last week")},
      {"month", gettext("Last month")}
    ]

  defp kinds,
    do: [
      {"one_way", gettext("One way")},
      {"alt_correction", gettext("Both ways")}
    ]

  defp kind_label("alt_correction"), do: gettext("Both ways")
  defp kind_label(_kind), do: gettext("One way")

  # The page address, with the defaults left out of the query.
  defp path(scope_prefix, dataset, surface, period) do
    query =
      [{"surface", surface, "documents"}, {"period", period, "week"}]
      |> Enum.reject(fn {_key, value, default} -> value == default end)
      |> Enum.map(fn {key, value, _default} -> {key, value} end)

    base = Paths.studio_path(scope_prefix, ["search"], dataset)
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp top_queries(%{topQueries: rows}) when is_list(rows), do: rows
  defp top_queries(_insights), do: []

  defp zero_hit_queries(insights),
    do: insights |> top_queries() |> Enum.filter(&(&1.zeroHitCount > 0))

  defp candidates(%{synonymCandidates: rows}) when is_list(rows), do: rows
  defp candidates(_insights), do: []

  defp percent(rate) when is_number(rate), do: "#{Float.round(rate * 100.0, 1)} %"
  defp percent(_rate), do: "0.0 %"

  defp delta(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp delta(n) when is_integer(n) and n < 0, do: "−#{abs(n)}"
  defp delta(_n), do: "0"

  defp period_range("day", %{periodStart: %Date{} = start}), do: Date.to_iso8601(start)

  defp period_range("month", %{periodStart: %Date{} = start}),
    do: range(start, Date.end_of_month(start))

  defp period_range(_period, %{periodStart: %Date{} = start}),
    do: range(start, Date.add(start, 6))

  defp period_range(_period, _insights), do: ""

  defp range(from, to), do: "#{Date.to_iso8601(from)} – #{Date.to_iso8601(to)}"
end
