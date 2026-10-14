defmodule Barkpark.PortableDoc.Render.Chrome do
  @moduledoc """
  The renderer's own words — chrome, never author content — in the render's
  locale (task-8e96278fc4ee7097).

  `strings/0` is the ONE word list: each key is the English text the renderer
  emits (the msgid, byte for byte), each value its translation in the current
  gettext locale. `Render.in_locale/2` builds the map once per render and puts
  it on the process; emitters call `t/1,2`, which answers the English key when
  no map is set — so a render without `:locale` is byte-identical to before.

  The @barkpark/react mirror takes the same map as its `strings` option, keyed
  by the same English text, and the nb pd-parity golden stores this map so both
  renderers are checked against one Norwegian.

  `%{name}` slots are filled by `t/2` after lookup, in both renderers.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  @key :barkpark_pd_chrome

  @doc "Every chrome word, English key => translation in the current locale."
  def strings do
    %{
      # forms
      "Recommendation: " => gettext("Recommendation: "),
      "Yes" => pgettext("answer", "Yes"),
      "No" => pgettext("answer", "No"),
      # field rows
      "No image" => gettext("No image"),
      # tasks, task detail, task board, roadmap
      "No tasks yet." => gettext("No tasks yet."),
      "tasks unavailable — the Tasks plugin is not loaded" =>
        gettext("tasks unavailable — the Tasks plugin is not loaded"),
      "No matching tasks." => gettext("No matching tasks."),
      "created %{when}" => gettext("created %{when}", when: "%{when}"),
      "updated %{when}" => gettext("updated %{when}", when: "%{when}"),
      "Criteria · %{met}/%{total}" =>
        gettext("Criteria · %{met}/%{total}", met: "%{met}", total: "%{total}"),
      "blocks %{n} task" => gettext("blocks %{n} task", n: "%{n}"),
      "blocks %{n} tasks" => gettext("blocks %{n} tasks", n: "%{n}"),
      "blocked by %{n}" => gettext("blocked by %{n}", n: "%{n}"),
      "Dependencies" => gettext("Dependencies"),
      "Children" => gettext("Children"),
      "Papers" => gettext("Papers"),
      "%{label} · %{done}/%{total} done" =>
        gettext("%{label} · %{done}/%{total} done",
          label: "%{label}",
          done: "%{done}",
          total: "%{total}"
        ),
      "… and %{n} more" => gettext("… and %{n} more", n: "%{n}"),
      "in flight" => gettext("in flight"),
      "DRAFT" => gettext("DRAFT"),
      "No roadmap items." => gettext("No roadmap items."),
      "No schedule to place these items on." => gettext("No schedule to place these items on."),
      "not scheduled" => gettext("not scheduled"),
      # field rows, composites, terminal, paper links
      "live" => gettext("live"),
      "Explore the work" => gettext("Explore the work"),
      "Why it matters:" => gettext("Why it matters:"),
      "rev %{n}" => gettext("rev %{n}", n: "%{n}"),
      "Live edition" => gettext("Live edition"),
      "Edition" => gettext("Edition"),
      # callout tone fallbacks, checklist boxes, master refs, inline chips, sheets
      "Info" => gettext("Info"),
      "Success" => gettext("Success"),
      "Warning" => gettext("Warning"),
      "Danger" => gettext("Danger"),
      "Neutral" => gettext("Neutral"),
      "Loss" => gettext("Loss"),
      "Peace" => gettext("Peace"),
      "Done" => gettext("Done"),
      "To do" => gettext("To do"),
      "Linked master" => gettext("Linked master"),
      "Master unavailable" => gettext("Master unavailable"),
      "criteria unavailable" => gettext("criteria unavailable"),
      "Accept new baseline: update the pinned literal to the current value" =>
        gettext("Accept new baseline: update the pinned literal to the current value"),
      "accept" => gettext("accept"),
      # equations, media links (email), data viz
      "equation — no tex source" => gettext("equation — no tex source"),
      "Terminal recording" => gettext("Terminal recording"),
      "Watch the video" => gettext("Watch the video"),
      "%{kind} — no data" => gettext("%{kind} — no data", kind: "%{kind}"),
      "less" => gettext("less"),
      "more" => gettext("more"),
      "series %{n}" => gettext("series %{n}", n: "%{n}"),
      "now %{value}" => gettext("now %{value}", value: "%{value}"),
      "(none)" => gettext("(none)"),
      "Total" => gettext("Total"),
      "route track" => gettext("route track"),
      "Open the paper to see the live chart." => gettext("Open the paper to see the live chart."),
      "Open the paper to see the live progress." =>
        gettext("Open the paper to see the live progress."),
      # the data-viz source stamp (task-c5c0f4fa42848256)
      "Source" => pgettext("data source", "Source"),
      "Sources" => pgettext("data source", "Sources"),
      # stat trial dots: "2 of 10" (pe-bl-stat-tile-dots)
      "%{on} of %{total}" => gettext("%{on} of %{total}", on: "%{on}", total: "%{total}"),
      "Sheet truncated — showing the first %{n} rows" =>
        gettext("Sheet truncated — showing the first %{n} rows", n: "%{n}"),
      # task status vocabulary (design/status-manifest.json labels)
      "open" => pgettext("task status", "open"),
      "ready" => pgettext("task status", "ready"),
      "in progress" => pgettext("task status", "in progress"),
      "blocked" => pgettext("task status", "blocked"),
      "done" => pgettext("task status", "done"),
      "cancelled" => pgettext("task status", "cancelled"),
      "considering" => pgettext("task status", "considering"),
      "researching" => pgettext("task status", "researching"),
      # task status meanings (the legend gloss, same manifest)
      "backlog — not ready yet" => gettext("backlog — not ready yet"),
      "unchecked — claim it now" => gettext("unchecked — claim it now"),
      "being worked right now" => gettext("being worked right now"),
      "something is required first" => gettext("something is required first"),
      "complete" => gettext("complete"),
      "abandoned or superseded" => gettext("abandoned or superseded"),
      "a candidate being weighed" => gettext("a candidate being weighed"),
      "under active investigation" => gettext("under active investigation")
    }
  end

  @doc "Run `fun` with the chrome map for the current gettext locale on the process."
  def with_strings(fun) when is_function(fun, 0) do
    prev = Process.get(@key)
    Process.put(@key, strings())

    try do
      fun.()
    after
      if prev, do: Process.put(@key, prev), else: Process.delete(@key)
    end
  end

  @doc "The chrome word `english` in the render's locale (English when none is set)."
  def t(english, vars \\ []) when is_binary(english) do
    template =
      case Process.get(@key) do
        %{} = map -> Map.get(map, english, english)
        _ -> english
      end

    Enum.reduce(vars, template, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end
end
