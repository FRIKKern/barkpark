defmodule BarkparkWeb.Studio.Desk.ReviewDiff do
  @moduledoc """
  One field's change in Review changes (`ReviewChanges`), drawn as the
  TanStack Studio's `ChangeView` draws it (Sanity's field diffs):

  - text: a word diff, removed words struck through, added ones marked;
  - a slug, a number, a yes/no, a date or a picked option: what it was →
    what it is (`.review-fromto`);
  - a reference: the document it pointed to → the one it points to, by
    title;
  - a list: each item added, removed or moved (`.review-array`), by its
    title, its words or its value;
  - rich text: only the blocks that changed, in their own style
    (`.review-blocks`), each with its word diff; a block whose marks alone
    changed says "Formatting changed";
  - an image: the picture before → after, then its other fields;
  - an object: its fields that changed, each before → after.

  Each mark's tooltip says who made it ("Added by Ada"). What the TanStack
  Studio draws and this does not: rich text's marks, links and inline
  objects inside a changed block (its words only), a changed chip's
  popover, a yes/no's switch (its words "On" / "Off"), and the image's
  file name and size.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.FieldDiff

  attr :change, :map, required: true
  attr :titles, :map, default: %{}, doc: "referenced documents' titles, by id"

  @doc "The change of one field."
  def change(assigns) do
    %{change: c} = assigns
    assigns = assign(assigns, view: view(c), by: by(c[:author]))

    ~H"""
    <%= case @view do %>
      <% {:fromto, was, now} -> %>
        <p class="review-diff review-fromto">
          <del :if={was} title={@by.(:removed)}>{was}</del>
          <span :if={was && now} class="review-arrow" aria-label={gettext("changed to")}>→</span>
          <ins :if={now} title={@by.(:added)}>{now}</ins>
        </p>
      <% {:ref, was, now} -> %>
        <p class="review-diff review-fromto">
          <del :if={was} title={@by.(:removed)}>{@titles[was] || was}</del>
          <span :if={was && now} class="review-arrow" aria-label={gettext("changed to")}>→</span>
          <ins :if={now} title={@by.(:added)}>{@titles[now] || now}</ins>
        </p>
      <% {:array, items} -> %>
        <ul class="review-diff review-array">
          <li :for={{item, kind} <- items} data-kind={kind}>
            <%= case kind do %>
              <% :added -> %><ins title={@by.(:added)}>{label(item, @titles)}</ins>
              <% :removed -> %><del title={@by.(:removed)}>{label(item, @titles)}</del>
              <% _ -> %><span>{label(item, @titles)}</span>
            <% end %>
            <span :if={kind == :moved} class="review-moved">{gettext("Moved")}</span>
          </li>
        </ul>
      <% {:blocks, blocks} -> %>
        <div class="review-diff review-blocks">
          <.dynamic_tag :for={b <- blocks} tag_name={b.tag} data-change={b.kind}>
            <%= if b.kind == :formatted do %>
              <span class="review-formatted" title={@by.(:formatted)}>{segments_text(b.segments)}</span>
            <% else %>
              <.segments segments={b.segments} by={@by} />
            <% end %>
          </.dynamic_tag>
        </div>
      <% {:image, was, now, attrs} -> %>
        <div class="review-diff review-img-change">
          <p :if={was != now} class="review-img">
            <.picture url={was} alt={gettext("Before")} none={gettext("No image")} />
            <span aria-hidden="true">→</span>
            <.picture url={now} alt={gettext("After")} none={gettext("Removed")} />
          </p>
          <.attrs attrs={attrs} by={@by} />
        </div>
      <% {:object, attrs} -> %>
        <div class="review-diff"><.attrs attrs={attrs} by={@by} /></div>
      <% {:text, segments} -> %>
        <p class="review-diff"><.segments segments={segments} by={@by} /></p>
      <% {:word, word} -> %>
        <p class="review-diff muted">{word}</p>
    <% end %>
    """
  end

  attr :segments, :list, required: true
  attr :by, :any, required: true

  defp segments(assigns) do
    ~H"""
    <%= for {kind, text} <- @segments do %><%= case kind do %><% :removed -> %><del title={@by.(:removed)}>{text}</del><% :added -> %><ins title={@by.(:added)}>{text}</ins><% _ -> %><span>{text}</span><% end %><% end %>
    """
  end

  attr :url, :string, default: nil
  attr :alt, :string, required: true
  attr :none, :string, required: true

  defp picture(assigns) do
    ~H"""
    <img :if={@url} src={@url} alt={@alt} />
    <span :if={!@url} class="review-img-none">{@none}</span>
    """
  end

  attr :attrs, :list, required: true
  attr :by, :any, required: true

  # An object's (or an image's) fields that changed: name, then before → after.
  defp attrs(assigns) do
    ~H"""
    <p :for={{label, was, now} <- @attrs} class="review-attr">
      <span class="review-attr-name">{label}</span>
      <%= if was == :object or now == :object do %>
        <span class="muted">{gettext("Changed")}</span>
      <% else %>
        <del title={@by.(:removed)}>{was}</del>
        <span class="review-arrow" aria-hidden="true">→</span>
        <ins title={@by.(:added)}>{now}</ins>
      <% end %>
    </p>
    """
  end

  # How a change is drawn, as TanStack's ChangeView picks it.
  defp view(%{field: field, before: before, after: after_}) do
    type = field["type"]
    labels = {value_label(field, before), value_label(field, after_)}

    cond do
      type == "image" or image?(before) or image?(after_) ->
        {:image, image_url(before), image_url(after_),
         attrs(field, before, after_, ~w(asset _type _key assetId url))}

      FieldDiff.blocks?(before) or FieldDiff.blocks?(after_) ->
        {:blocks, FieldDiff.blocks_diff(before, after_)}

      type == "reference" ->
        {:ref, ref_id(before), ref_id(after_)}

      is_list(before) or is_list(after_) ->
        {:array,
         before
         |> List.wrap()
         |> FieldDiff.array_diff(List.wrap(after_))
         |> Enum.reject(&(elem(&1, 1) == :kept))}

      labels != {:none, :none} ->
        {:fromto, shown(elem(labels, 0)), shown(elem(labels, 1))}

      type == "slug" ->
        {:fromto, blank(FieldDiff.as_text(before)), blank(FieldDiff.as_text(after_))}

      is_map(before) and is_map(after_) ->
        {:object, attrs(field, before, after_, [])}

      true ->
        case {FieldDiff.as_text(before), FieldDiff.as_text(after_)} do
          {b, a} when is_binary(b) and is_binary(a) -> {:text, FieldDiff.text_diff(b, a)}
          _ -> {:word, word(before, after_)}
        end
    end
  end

  defp word(nil, _after), do: gettext("Added")
  defp word(_before, nil), do: gettext("Removed")
  defp word(_before, _after), do: gettext("Changed")

  defp shown(:none), do: nil
  defp shown(label), do: label

  defp blank(""), do: nil
  defp blank(text), do: text

  # A number, a yes/no, a date or a picked option, as the input shows it;
  # `:none` for a field that is not one of those, or no value.
  defp value_label(_field, v) when v in [nil, ""], do: :none

  defp value_label(%{"type" => "boolean"}, v) when is_boolean(v),
    do: if(v, do: gettext("On"), else: gettext("Off"))

  defp value_label(%{"type" => "number"}, v) when is_number(v), do: to_string(v)
  defp value_label(%{"type" => t}, v) when t in ~w(date datetime) and is_binary(v), do: v

  defp value_label(%{"options" => options} = field, v) when is_binary(v) or is_number(v) do
    case option_list(options) do
      [_ | _] = list ->
        hit = Enum.find(list, &(option_value(&1) == v))
        if hit, do: to_string(option_title(hit) || v), else: to_string(v)

      _ ->
        value_label(Map.delete(field, "options"), v)
    end
  end

  defp value_label(_field, _v), do: :none

  defp option_list(%{"list" => list}) when is_list(list), do: list
  defp option_list(list) when is_list(list), do: list
  defp option_list(_options), do: []

  defp option_value(%{"value" => v}), do: v
  defp option_value(v), do: v
  defp option_title(%{} = o), do: o["title"] || o["label"]
  defp option_title(v), do: v

  defp ref_id(%{"_ref" => id}) when is_binary(id) and id != "",
    do: Barkpark.Content.published_id(id)

  defp ref_id(_value), do: nil

  defp image?(%{"asset" => _}), do: true
  defp image?(%{"assetId" => _}), do: true
  defp image?(_value), do: false

  defp image_url(%{"url" => url}) when is_binary(url) and url != "", do: url
  defp image_url(url) when is_binary(url) and url != "", do: url
  defp image_url(_value), do: nil

  # An object's subfields that changed (leaving out `skip` and `_`-keys):
  # `{label, before, after}`, a value that is an object being `:object`.
  defp attrs(field, before, after_, skip) do
    {was, now} = {map(before), map(after_)}
    subs = Map.new(List.wrap(field["fields"]), &{&1["name"], &1["title"]})
    names = %{"alt" => gettext("Alternative text"), "caption" => gettext("Caption")}

    (Map.keys(was) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in skip or String.starts_with?(&1, "_")))
    |> Enum.reject(&FieldDiff.same?(was[&1], now[&1]))
    |> Enum.sort()
    |> Enum.map(&{subs[&1] || names[&1] || &1, attr(was[&1]), attr(now[&1])})
  end

  defp map(%{} = m), do: m
  defp map(_value), do: %{}

  defp attr(v) when v in [nil, ""], do: "—"
  defp attr(v) when is_map(v) or is_list(v), do: :object
  defp attr(v), do: to_string(v)

  # One list item, as its row reads: a reference's title, an object's
  # title or words, a value.
  defp label(%{"_ref" => id}, titles), do: titles[Barkpark.Content.published_id(id)] || id

  defp label(%{} = item, _titles) do
    item["title"] || item["name"] || item["label"] ||
      FieldDiff.block_text(item) |> blank() ||
      item |> Map.drop(["_key", "_type"]) |> Map.values() |> Enum.find(&is_binary/1) ||
      item["_type"] || "—"
  end

  defp label(item, _titles), do: to_string(item)

  defp segments_text(segments), do: Enum.map_join(segments, &elem(&1, 1))

  # Who made a mark, for its tooltip, as Sanity says it.
  defp by(nil) do
    fn
      :added -> gettext("Added")
      :removed -> gettext("Removed")
      :formatted -> gettext("Formatting changed")
    end
  end

  defp by(author) do
    fn
      :added -> gettext("Added by %{author}", author: author)
      :removed -> gettext("Removed by %{author}", author: author)
      :formatted -> gettext("Formatting changed by %{author}", author: author)
    end
  end

  @doc """
  The TanStack Studio's `.review` look (barkpark-studio `styles.css`), in
  the desk's tokens, and the confirm the reverts open.
  """
  def sheet(assigns) do
    ~H"""
    <style>
      .dk .review { margin: 0 8px; line-height: 19px; }
      .dk .review-range { display: grid; grid-template-columns: 48px 1fr; align-items: center; gap: 4px; margin: 24px 0 16px; }
      .dk .review-range > div { display: contents; }
      .dk .review-range dt { color: var(--dk-muted); }
      .dk .review-range dd { margin: 0; min-width: 0; }
      .dk .review .menu-wrap { display: block; position: relative; }
      .dk .review-pick { display: flex; align-items: center; justify-content: space-between; gap: 4px; width: 100%; padding: 3px 2px 3px 8px; border: 0; border-radius: 3px; background: var(--dk-card-hover); box-shadow: inset 0 0 0 1px var(--dk-border); color: var(--dk-fg); font: inherit; font-size: 13px; font-weight: 500; line-height: 19px; text-align: left; }
      .dk .review-pick > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .review-pick svg { flex: none; margin: -1px 0; color: var(--dk-icon-muted); }
      .dk .review-empty { padding: 15px 0 32px; }
      .dk .review-empty h3 { margin: 0 0 2px; font-size: 13px; font-weight: 500; }
      .dk .review-empty p { margin: 0; color: var(--dk-muted); }
      .dk .review-list { display: flex; flex-direction: column; gap: 15px; margin: 0; padding: 7px 0 0; list-style: none; }
      .dk .review-list li { padding: 4px 0; }
      .dk .review-head { display: flex; align-items: center; gap: 8px; }
      .dk .review-field { flex: 1; font-weight: 500; }
      .dk .review-body { display: flex; align-items: flex-start; gap: 4px; padding-left: 7px; border-left: 1px solid var(--dk-border); }
      .dk .review-body > .review-diff { flex: 1; min-width: 0; }
      .dk .review-diff { margin: 6px 0 0; font-size: 16px; line-height: 22px; white-space: pre-wrap; word-break: break-word; }
      .dk .review-diff del, .dk .review-diff ins { border-radius: 1px; background: var(--dk-diff-bg); color: var(--dk-diff-fg); }
      .dk .review-diff del { text-decoration: line-through; }
      .dk .review-diff ins { text-decoration: none; }
      .dk .review-diff.muted, .dk .review .muted { color: var(--dk-muted); }
      .dk .review-fromto { display: flex; flex-wrap: wrap; align-items: center; }
      .dk .review-fromto del, .dk .review-fromto ins { padding: 3px 8px; border-radius: 3px; }
      .dk .review-arrow { flex: none; width: 14px; text-align: center; font-size: 13px; color: var(--dk-muted); }
      .dk .review-blocks { white-space: normal; }
      .dk .review-blocks > * { margin: 0 0 8px; }
      .dk .review-blocks :is(h1, h2) { font-size: 21px; line-height: 27px; font-weight: 700; }
      .dk .review-blocks :is(h3, h4) { font-size: 18px; line-height: 24px; font-weight: 700; }
      .dk .review-blocks :is(h5, h6) { font-size: 16px; line-height: 22px; font-weight: 700; }
      .dk .review-blocks li { margin-left: 20px; display: list-item; }
      .dk .review-blocks blockquote { padding-left: 12px; border-left: 2px solid var(--dk-border); }
      .dk .review-blocks [data-change=removed] { opacity: 0.7; }
      .dk .review-formatted { text-decoration: underline dotted currentColor; text-decoration-thickness: 2px; text-underline-offset: 3px; }
      .dk .review-attr { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 4px 0 0; font-size: 12px; }
      .dk .review-attr-name { color: var(--dk-muted); }
      .dk .review-attr :is(del, ins) { padding: 0 4px; border-radius: 3px; }
      .dk .review-array { display: flex; flex-direction: column; gap: 4px; margin: 6px 0 0; padding: 0; list-style: none; }
      .dk .review-array li { display: flex; align-items: center; gap: 8px; padding: 0; }
      .dk .review-array :is(del, ins) { padding: 1px 6px; border-radius: 3px; }
      .dk .review-moved { font-size: 12px; color: var(--dk-muted); }
      .dk .review-img { display: flex; align-items: center; gap: 8px; }
      .dk .review-img :is(img, .review-img-none) { width: 96px; height: 64px; object-fit: cover; border-radius: 3px; background: var(--dk-card-hover); box-shadow: inset 0 0 0 1px var(--dk-border); }
      .dk .review-img-none { display: grid; place-items: center; font-size: 12px; color: var(--dk-muted); }
      .dk .review .revert-one { flex: none; display: grid; place-items: center; width: 33px; height: 33px; margin-top: 1px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .review .revert-one:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
      .dk .review .revert-all { display: inline-flex; align-items: center; gap: 6px; margin: 16px 0 0; padding: 7px 12px 7px 8px; border: 0; border-radius: 3px; background: none; box-shadow: inset 0 0 0 1px var(--dk-border); color: var(--dk-fg); font: inherit; font-size: 13px; font-weight: 500; cursor: pointer; }
      .dk .review .revert-all:hover { background: var(--dk-card-hover); }
      .dk .review :is(.revert-one, .revert-all):focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      .dk .review .dk-confirm { width: 320px; padding: 0; }
      .dk .review .dk-confirm p { margin: 0; padding: 16px; font-size: 13px; border-bottom: 1px solid var(--dk-border); }
      .dk .review .dk-confirm .confirm-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; padding: 8px; }
      @media (pointer: coarse) { .dk .review .dk-confirm .btn, .dk .review .revert-one { min-height: 44px; min-width: 44px; } }
    </style>
    """
  end
end
