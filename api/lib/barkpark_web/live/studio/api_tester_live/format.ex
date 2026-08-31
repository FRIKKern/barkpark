defmodule BarkparkWeb.Studio.ApiTesterLive.Format do
  @moduledoc "Pure view formatters for the API-tester LiveView — icons, badges, and value formatting, extracted so the LiveView is the orchestration shell."

  def docs_column_title(nil), do: "—"
  def docs_column_title(%{kind: :reference, label: label}), do: label

  def docs_column_title(%{kind: :endpoint, method: method, path_template: path}),
    do: "#{method} #{path}"

  # Auth level → existing design-system badge variant
  def auth_badge_class(:public), do: "badge-public"
  def auth_badge_class(:token), do: "badge-draft"
  def auth_badge_class(:admin), do: "badge-active"
  def auth_badge_class(_), do: "badge-active"

  # Icons for the left-pane nav, reusing the small set already in
  # BarkparkWeb.Icons so the API pane renders the same look as Structure.
  def category_icon("Reference"), do: "file-text"
  def category_icon("Query"), do: "layout-list"
  def category_icon("Mutate"), do: "settings"
  def category_icon("Real-time"), do: "compass"
  def category_icon("Schemas"), do: "folder"
  def category_icon("Export"), do: "file"
  def category_icon("History"), do: "file-text"
  def category_icon("Analytics"), do: "tag"
  def category_icon("Webhooks"), do: "compass"
  def category_icon(_), do: "file"

  # Per-endpoint icon. Uses only icons that exist in Icons.@icons;
  # unknown names fall back to "file" via the Icons component.
  def endpoint_icon(%{id: "ref-envelope"}), do: "file-text"
  def endpoint_icon(%{id: "ref-errors"}), do: "file"
  def endpoint_icon(%{id: "ref-limits"}), do: "settings"
  def endpoint_icon(%{id: "query-list"}), do: "layout-list"
  def endpoint_icon(%{id: "query-single"}), do: "file"
  def endpoint_icon(%{category: "Mutate"}), do: "settings"
  def endpoint_icon(%{id: "listen-sse"}), do: "compass"
  def endpoint_icon(%{id: "schemas-list"}), do: "layout-list"
  def endpoint_icon(%{id: "schemas-show"}), do: "file-text"
  def endpoint_icon(_), do: "file"

  # Pretty-print assert tagged tuples for the response panel — turns
  # `{:status, 200}` into `status == 200`, `{:body_contains, "x"}` into
  # `body contains "x"`, etc. Falls back to `inspect/1` for unknown tags
  # so a new assert kind shows up readably instead of crashing the render.
  def format_assertion({:status, n}), do: "status == #{n}"
  def format_assertion({:body_contains, s}), do: ~s|body contains "#{s}"|
  def format_assertion({:body_regex, re}), do: "body matches #{inspect(re)}"
  def format_assertion({:json_path, path, _fun}), do: "json[#{Enum.join(path, ".")}] predicate"
  def format_assertion({:json_keys_include, keys}), do: "json keys ⊇ #{inspect(keys)}"
  def format_assertion({:header, name, _v}), do: ~s|header "#{name}"|
  def format_assertion(:not_empty), do: "body not empty"
  def format_assertion({:duration_under_ms, n}), do: "duration < #{n}ms"
  def format_assertion(other), do: inspect(other)

  def format_body(%{body_json: json}) when is_map(json) or is_list(json),
    do: Jason.encode!(json, pretty: true)

  def format_body(%{body_text: text}) when is_binary(text) and text != "", do: text
  def format_body(_), do: ""

  def verdict_badge_class(:pass), do: "badge-verdict-pass"
  def verdict_badge_class(:fail), do: "badge-verdict-fail"
  def verdict_badge_class(:unverified), do: "badge-verdict-unverified"
  def verdict_badge_class(_), do: "badge-verdict-error"
end
