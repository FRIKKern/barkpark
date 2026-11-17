defmodule BarkparkWeb.Studio.Desk.ValidationPanel do
  @moduledoc """
  Sanity's Validation inspector for the document in the desk's edit pane, as
  the TanStack Studio draws it (`DocumentPane.tsx` `ValidationPanel`): a
  header button named "Validation" while the document has a problem, and a
  panel beside the form that lists every problem. Picking one goes to its
  field: the field's group is chosen, a folded fieldset or object on the way
  is opened, and the field takes the focus (`bp-desk-validation.js`).

  It is open while the pane's URL says so (`inspect=sanity/structure/validation`,
  Sanity's own name). The button and the panel's close button are patches, so
  Back closes or reopens it, and a reload keeps it.

  THE PROBLEMS are `Barkpark.Content.Validation.check_findings/3` over the
  document the editor holds (`editor_doc`) and its schema: the same walk the
  save runs, read again when the pane renders. So a document that is opened
  with a bad value lists it before any edit, and a typed value is listed once
  its autosave has landed. Nothing is validated here that the save does not
  validate: a rule the server does not have (TanStack checks a `url` field's
  shape in the browser) is not listed.

  Errors block Publish (`DocFooter`); warnings are listed and never block.
  The server reads an `info` rule as a warning, so it is listed as one.

  A problem's words are the TanStack Studio's (`lib/validation.ts`), by the
  finding's code; a code with no sentence here keeps the server's own.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.Validation
  alias BarkparkWeb.Studio.Desk.FieldGroups
  alias BarkparkWeb.Studio.Desk.Panes
  alias Phoenix.LiveView.JS

  @typedoc """
  One problem. `path` is the field's id in the form (`rating`, `seo.title`,
  `links[_key=="l1"].url`); `parents` are the titles of what it sits in.
  """
  @type problem :: %{
          path: String.t(),
          title: String.t(),
          parents: [String.t()],
          message: String.t(),
          level: String.t(),
          group: String.t() | nil,
          item: String.t() | nil
        }

  @doc "Whether `pane` asks for this inspector."
  def open?(%{kind: :doc, inspect: "validation"}), do: true
  def open?(_pane), do: false

  @doc "The open document's problems in the form's order, a field's errors first."
  @spec problems(map()) :: [problem()]
  def problems(%{editor_doc: %{} = doc, editor_schema: %{} = schema}) do
    content = Map.get(doc, :content) || %{}
    fields = fields(schema)
    %{errors: errors, warnings: warnings} = Validation.check_findings(content, doc.title, schema)

    found =
      for {level, findings} <- [{"error", errors}, {"warning", warnings}],
          finding <- findings,
          do: problem(finding, level, fields, content)

    order = fields |> Enum.with_index() |> Map.new(fn {f, i} -> {f["name"], i} end)
    Enum.sort_by(found, &Map.get(order, top(&1.path), map_size(order)))
  end

  def problems(_assigns), do: []

  @doc "How many of `problems` block Publish."
  @spec blocking([problem()]) :: non_neg_integer()
  def blocking(problems), do: Enum.count(problems, &(&1.level == "error"))

  defp fields(%{fields: fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp fields(%{"fields" => fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp fields(_schema), do: []

  defp top(path), do: path |> String.split([".", "["], parts: 2) |> hd()

  defp problem(finding, level, fields, content) do
    segments = finding.path |> to_string() |> String.split("/", trim: true)
    {path, title, parents, leaf} = place(segments, fields, content, "", nil, [], nil)
    first = Enum.find(fields, &(&1["name"] == List.first(segments)))

    %{
      path: path,
      title: title || List.first(segments) || "",
      parents: parents,
      message: words(finding, leaf, level),
      level: level,
      # The row of the array the field sits in, by index, for the jump.
      item: Enum.find_value(segments, &(match?({_, ""}, Integer.parse(&1)) && &1)),
      group: group(first)
    }
  end

  defp group(%{"group" => group}) when is_binary(group) and group != "", do: group
  defp group(%{"group" => [group | _]}) when is_binary(group), do: group
  defp group(_field), do: nil

  # Walks a finding's path ("/links/0/url") down the schema and the stored
  # value. Answers the field's id in the form, its title, and the titles of
  # what it sits in: an array, the item's kind, an object.
  defp place([], _fields, _value, path, title, parents, leaf),
    do: {path, title, Enum.reverse(parents), leaf}

  defp place([seg | rest], fields, value, path, title, parents, _leaf) do
    field = Enum.find(List.wrap(fields), &(is_map(&1) and &1["name"] == seg))
    here = if path == "", do: seg, else: path <> "." <> seg
    parents = if title, do: [title | parents], else: parents
    inner = if is_map(value), do: Map.get(value, seg)
    name = (field && field["title"]) || seg

    case {rest, inner} do
      {[index | more], list} when is_list(list) ->
        item(Integer.parse(index), more, field, list, here, name, parents)

      _ ->
        place(rest, field && field["fields"], inner, here, name, parents, field)
    end
  end

  # An array's item: named by its `_key` when it has one, as the form's ids.
  defp item({i, ""}, rest, field, list, here, name, parents) do
    row = Enum.at(list, i)

    at =
      case row do
        %{"_key" => key} when is_binary(key) and key != "" -> ~s(#{here}[_key=="#{key}"])
        _ -> "#{here}[#{i}]"
      end

    {member_fields, kind} = member(field && field["of"], row)

    case rest do
      [] ->
        {at, name, Enum.reverse(parents), field}

      _ ->
        up = Enum.reject([kind, name], &is_nil/1) ++ parents
        place(rest, member_fields, row, at, nil, up, nil)
    end
  end

  defp item(_not_an_index, rest, field, list, here, name, parents),
    do: place(rest, field && field["fields"], list, here, name, parents, field)

  # The fields of an item and the title of its kind: one composite whose
  # `typeField` names the kind, or the member the item's `_type` names.
  defp member(%{"fields" => fields} = of, row) when is_map(row) do
    type_field = get_in(of, ["options", "typeField"])
    kind = type_field && row[type_field]
    options = Enum.find(fields, &(is_map(&1) and &1["name"] == type_field))["options"]

    title =
      if is_binary(kind) do
        option = Enum.find(List.wrap(options), &(is_map(&1) and &1["value"] == kind))
        (option && option["title"]) || kind
      end

    {fields, title}
  end

  defp member(members, %{"_type" => type}) when is_list(members) do
    case Enum.find(members, &(is_map(&1) and (&1["name"] || &1["type"]) == type)) do
      %{} = found -> {found["fields"], found["title"] || type}
      nil -> {nil, nil}
    end
  end

  defp member(_of, _row), do: {nil, nil}

  # The TanStack Studio's sentence for a finding's code.
  # A pattern rule with no message of its own names its pattern.
  defp words(finding, leaf, level) do
    with %{code: :pattern_mismatch} <- finding,
         level = if(level == "error", do: :error, else: :warning),
         %{"pattern" => pattern} when is_binary(pattern) <-
           Validation.rules_at(is_map(leaf) && leaf["validation"], level) do
      gettext("Does not match %{pattern}-pattern", pattern: ~s("/#{pattern}/"))
    else
      _ -> words(finding)
    end
  end

  defp words(%{code: :required}), do: gettext("Required")

  defp words(%{code: :number_too_large, params: %{max: max}}),
    do: gettext("Must be lower than or equal to %{max}", max: max)

  defp words(%{code: :number_too_small, params: %{min: min}}),
    do: gettext("Must be greater than or equal to %{min}", min: min)

  defp words(%{code: :string_too_long, params: %{max: max}}),
    do: gettext("Must be at most %{max} characters long", max: max)

  defp words(%{code: :string_too_short, params: %{min: min}}),
    do: gettext("Must be at least %{min} characters long", min: min)

  defp words(%{code: :list_too_long, params: %{max: max}}),
    do: gettext("Must have at most %{max} items", max: max)

  defp words(%{code: :list_too_short, params: %{min: min}}),
    do: gettext("Must have at least %{min} items", min: min)

  defp words(%{code: :list_not_unique}), do: gettext("Can't be a duplicate")

  # The server's own sentence, without the path it puts before a nested one.
  defp words(%{message: message}) do
    message
    |> to_string()
    |> String.replace(~r/^\/[^:]*: /, "")
    |> BarkparkWeb.StudioLocale.validation_message()
  end

  defp worst(problems) do
    cond do
      Enum.any?(problems, &(&1.level == "error")) -> "error"
      problems != [] -> "warning"
      true -> nil
    end
  end

  attr :id, :string, required: true
  attr :problems, :list, required: true

  @doc """
  What a screen reader hears when the errors change, in TanStack's words:
  how many, the first one, that Publish is blocked. Opening says nothing.
  """
  def status(assigns) do
    errors = Enum.filter(assigns.problems, &(&1.level == "error"))

    said =
      case errors do
        [first | _] ->
          count = ngettext("1 validation error", "%{count} validation errors", length(errors))
          "#{count}. #{first.title}: #{first.message}. " <> gettext("Publishing is blocked.")

        [] ->
          gettext("No validation errors")
      end

    assigns = assign(assigns, :said, said)

    # Empty when the document opens, as TanStack's: `bp-desk-validation.js`
    # writes the words in when they change.
    ~H"""
    <span id={@id} class="sr-only" role="status" phx-update="ignore" data-desk-validation-status={@said}></span>
    """
  end

  attr :id, :string, required: true
  attr :problems, :list, required: true
  attr :pane, :map, required: true
  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true
  attr :perspective, :atom, default: :drafts

  @doc "The pane header's button, drawn while there is a problem or the panel is open."
  def button(assigns) do
    open = open?(assigns.pane)

    assigns =
      assign(assigns,
        open: open,
        level: worst(assigns.problems),
        toggle:
          patch(
            assigns.chain,
            assigns.index,
            %{inspect: if(open, do: nil, else: "validation"), rev: nil},
            assigns.base,
            assigns.perspective
          )
      )

    ~H"""
    <button
      :if={@perspective != :published and (@problems != [] or @open)}
      type="button"
      id={@id}
      class="icon-btn validation-btn"
      aria-label={gettext("Validation")}
      data-tip={gettext("Validation")}
      aria-pressed={to_string(@open)}
      data-problems={@problems != [] && length(@problems)}
      data-level={@level}
      phx-click={
        if @open,
          do: @toggle |> JS.patch() |> JS.dispatch("desk:validation-close", detail: %{button: @id}),
          else: JS.patch(@toggle)
      }
    >
      <.glyph level={@level || "error"} />
    </button>
    """
  end

  attr :id, :string, required: true, doc: "the panel's id (`<pane>-validation`)"

  attr :button, :string,
    required: true,
    doc: "the header button's id: the close gives it the focus"

  attr :problems, :list, required: true
  attr :pane, :map, required: true
  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true
  attr :perspective, :atom, default: :drafts
  attr :schema, :any, default: nil
  attr :nav_group, :any, default: nil
  attr :form, :any, default: nil

  @doc "The panel beside the form: every problem as a button, or a line saying none."
  def holder(assigns) do
    assigns =
      assign(assigns,
        open: open?(assigns.pane) and assigns.perspective != :published,
        group: FieldGroups.current(assigns.schema, assigns.nav_group, assigns.form),
        close:
          assigns.chain
          |> patch(assigns.index, %{inspect: nil}, assigns.base, assigns.perspective)
          |> JS.patch()
          # Where the focus goes is the browser's: the header button may be
          # gone once the panel is (`bp-desk-validation.js`).
          |> JS.dispatch("desk:validation-close", detail: %{button: assigns.button})
      )

    ~H"""
    <aside
      :if={@open}
      id={@id}
      class="dk-inspector inspector validation"
      aria-label={gettext("Validation")}
      data-desk-validation
    >
      <.sheet />
      <header class="dk-inspector-head">
        <h2>{gettext("Validation")}</h2>
        <button
          type="button"
          class="dk-inspector-close icon-btn"
          aria-label={gettext("Close validation")}
          phx-click={@close}
          phx-keydown={@close}
          phx-key="escape"
          data-desk-validation-close
        >
          <BarkparkWeb.Icons.desk_icon name="close" size={21} />
        </button>
      </header>
      <p :if={@problems == []} class="muted dk-problems-none">{gettext("No validation errors")}</p>
      <ul :if={@problems != []} class="problems">
        <li :for={problem <- @problems}>
          <button
            type="button"
            class="problem"
            data-level={problem.level}
            data-desk-problem={problem.path}
            phx-click={pick(problem, assigns)}
          >
            <span class="error-icon" data-level={problem.level} aria-hidden="true"><.glyph level={problem.level} /></span>
            <span>
              <strong><span :for={parent <- problem.parents} class="problem-parent">{parent} <span class="problem-slash">/</span>{" "}</span>{problem.title}</strong>
              <span>{problem.message}</span>
            </span>
          </button>
        </li>
      </ul>
    </aside>
    """
  end

  # Picking a problem, as the TanStack Studio's `goTo`: the field's own group
  # when a group is chosen and it is another one (All fields for a field in
  # none), the field's path in the URL, and the jump itself in the browser
  # once the field is drawn.
  defp pick(problem, assigns) do
    to =
      patch(
        assigns.chain,
        assigns.index,
        %{path: problem.path},
        assigns.base,
        assigns.perspective
      )

    js =
      if assigns.group && assigns.group != problem.group,
        do: JS.push("select-group", value: %{group: problem.group || ""}),
        else: %JS{}

    # A field inside an array item replaces the URL, as TanStack's.
    js
    |> JS.patch(to, replace: problem.item != nil)
    |> JS.dispatch("desk:goto-field", detail: %{path: problem.path, item: problem.item})
  end

  defp patch(chain, index, params, base, perspective),
    do: chain |> Panes.with_params(index, params, base) |> Panes.keep_perspective(perspective)

  attr :level, :string, required: true

  # Sanity's ErrorOutline and WarningOutline, as TanStack's `icons.tsx`.
  defp glyph(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" width="21" height="21" viewBox="0 0 25 25" fill="none" aria-hidden="true">
      <path
        :if={@level == "warning"}
        d="M12.5 9V13M12.5 16V14.5M14.2239 5.43058L20.727 16.486C21.5113 17.8192 20.55 19.5 19.0032 19.5H5.99683C4.45 19.5 3.48869 17.8192 4.27297 16.486L10.7761 5.43058C11.5494 4.11596 13.4506 4.11596 14.2239 5.43058Z"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linejoin="round"
      />
      <path
        :if={@level != "warning"}
        d="M12.5 16V14.5M12.5 9V13M20.5 12.5C20.5 16.9183 16.9183 20.5 12.5 20.5C8.08172 20.5 4.5 16.9183 4.5 12.5C4.5 8.08172 8.08172 4.5 12.5 4.5C16.9183 4.5 20.5 8.08172 20.5 12.5Z"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc """
  The header button's look (`Desk.DocStyle` draws the pane's sheet; this is
  drawn with the pane, because the button is there before the panel is):
  TanStack's `.validation-btn`, its glyph in the level's colour with a dot.
  """
  def button_sheet(assigns) do
    ~H"""
    <style>
      /* studio-literal-check: skip-begin (the desk's own look: the TanStack Studio's
         measured values, barkpark-studio app/src/styles.css, light and dark; main's ruling 11-13) */
      .dk .dk-doc > .pane-header .validation-btn { position: relative; cursor: pointer; --dk-critical-icon: #ef3d2f; --dk-caution-icon: #cf8212; }
      html[data-theme="dark"] .dk .dk-doc > .pane-header .validation-btn { --dk-critical-icon: #f3503e; --dk-caution-icon: #da951b; }
      /* studio-literal-check: skip-end */
      .dk .dk-doc > .pane-header .validation-btn[data-problems], .dk .dk-doc > .pane-header .validation-btn[data-problems]:hover { color: var(--dk-critical-icon); }
      .dk .dk-doc > .pane-header .validation-btn[data-level="warning"], .dk .dk-doc > .pane-header .validation-btn[data-level="warning"]:hover { color: var(--dk-caution-icon); }
      .dk .dk-doc > .pane-header .validation-btn[aria-pressed="true"] { background: var(--dk-selected-fill); }
      .dk .dk-doc > .pane-header .validation-btn::after { content: ""; position: absolute; top: calc(50% - 6.5px); left: calc(50% + 2.5px); width: 4px; height: 4px; border-radius: 3px; box-shadow: 0 0 0 1px var(--dk-bg); background: var(--dk-published); }
      .dk .dk-doc > .pane-header .validation-btn[data-level="warning"]::after { background: var(--dk-caution-dot); }
      .dk .dk-doc > .pane-header .validation-btn[data-level="error"]::after { background: var(--dk-critical-icon); }
      .dk .dk-doc > .pane-header .validation-btn[aria-pressed="true"]::after { box-shadow: 0 0 0 1px var(--dk-selected-fill); }
      .dk .dk-doc > .pane-header .validation-btn:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      @media (pointer: coarse) { .dk .dk-doc > .pane-header .validation-btn { min-width: 44px; min-height: 44px; } }
    </style>
    """
  end

  # The TanStack Studio's `.inspector` and `.problem` (barkpark-studio
  # `styles.css`): a third of the document pane and never under 320 px, each
  # problem a card in its level's tone. The pane body makes room with padding
  # (`IncomingRefs` says why). Drawn with the panel.
  defp sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-edit-body:has(> .dk-inspector.validation) { position: relative; padding-right: max(320px, 33.333%) !important; }
      .dk .dk-edit-body > .dk-inspector.validation { position: absolute; top: 0; right: 0; bottom: 0; box-sizing: border-box; width: max(320px, 33.333%); overflow: auto; padding: 11px 12px 12px; border-left: 1px solid var(--dk-border); background: var(--dk-bg); color: var(--dk-fg); font-size: 13px; line-height: 19px; }
      @media (max-width: 599px) {
        .dk .dk-edit-body:has(> .dk-inspector.validation) { padding-right: 0 !important; }
        .dk .dk-edit-body > .dk-inspector.validation { left: 0; width: auto; border-left: 0; z-index: 2; }
      }
      .dk .validation .dk-inspector-head { display: flex; align-items: center; justify-content: space-between; padding: 0 0 12px 8px; }
      .dk .validation .dk-inspector-head h2 { margin: 0; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); }
      .dk .validation .dk-inspector-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .validation .dk-inspector-close:hover { background: var(--dk-icon-btn-hover); color: var(--dk-fg); }
      .dk .validation .dk-inspector-close:focus-visible, .dk .validation .problem:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      .dk .validation .dk-problems-none { margin: 0; padding: 0 8px; color: var(--dk-muted); }
      .dk .validation .problems { list-style: none; margin: 12px 0 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
      /* studio-literal-check: skip-begin (the desk's own look: the TanStack Studio's
         measured values, barkpark-studio app/src/styles.css, light and dark; main's ruling 11-13) */
      .dk .validation .problem { --tone-bg: #fff6f5; --tone-fg: #4d1714; --tone-muted: #a8554f; --tone-icon: #cc2719; width: 100%; display: flex; gap: 6px; align-items: flex-start; text-align: left; font: inherit; font-size: 13px; padding: 8px 12px 7px 6px; border: 0; border-radius: 3px; background: var(--tone-bg); color: var(--tone-muted); cursor: pointer; }
      .dk .validation .problem[data-level="warning"] { --tone-bg: #fefae1; --tone-fg: #3b2212; --tone-muted: #8b6946; --tone-icon: #955712; }
      html[data-theme="dark"] .dk .validation .problem { --tone-bg: #24161b; --tone-fg: #ffdfdd; --tone-muted: #c78a85; --tone-icon: #f87c6f; }
      html[data-theme="dark"] .dk .validation .problem[data-level="warning"] { --tone-bg: #1e1a1b; --tone-fg: #f9ea98; --tone-muted: #c2a74b; --tone-icon: #f9bf1e; }
      /* studio-literal-check: skip-end */
      .dk .validation .problem svg { flex: none; width: 21px; height: 21px; }
      .dk .validation .problem span { display: flex; flex-direction: column; }
      .dk .validation .problem > span > span { line-height: 19px; }
      .dk .validation .problem strong { color: var(--tone-fg); font-weight: 500; }
      .dk .validation .problem strong span { display: inline; }
      .dk .validation .problem .problem-slash { color: var(--tone-muted); font-weight: 400; }
      .dk .validation .problem .error-icon { display: inline-grid; place-items: center; margin: -2px 0 0; color: var(--tone-icon); }
      @media (pointer: coarse) { .dk .validation .dk-inspector-close { min-width: 44px; min-height: 44px; } }
    </style>
    """
  end
end
