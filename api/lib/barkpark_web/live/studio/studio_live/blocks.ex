defmodule BarkparkWeb.Studio.StudioLive.Blocks do
  @moduledoc """
  Pure block-catalog helpers extracted from `BarkparkWeb.Studio.StudioLive`:
  the block-patch builders (`build_block_patch/2`), the `default_block/2`
  catalog (rich-text / visual / article-chrome / leaf `field-*` blocks), the
  MVP inline<->text converters, and the small param parsers. No socket, no
  side effects — every function here is a pure transform mirroring the block
  shapes in `Barkpark.PortableDoc.Render.compose_block/1,2`.
  """

  alias Barkpark.Content.Papers.CanvasRunContext
  alias BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor

  @doc false
  def block_form_source(params), do: Map.drop(params, ["if_rev", "request_id"])

  @doc false
  def resolve_block_form(blocks, %{"block_id" => id} = source) when is_binary(id) do
    case find_paper_block(blocks, id) do
      %{} = block ->
        case validate_block_patch(block, source) do
          {:ok, patch} -> {:ok, %{"op" => "patch-block", "id" => id, "patch" => patch}}
          {:error, reason} -> {:error, {:source_validation, reason}}
        end

      nil ->
        {:error, :block_not_found}
    end
  end

  def resolve_block_form(_blocks, _source), do: {:error, :invalid_block_form}

  @doc false
  # Build the patch map for a block from the submitted form params. Only the
  # editable field(s) for that block type are included; `id`/`type` are locked
  # by patch.ex regardless. Mirrors the EXACT block shapes in
  # Barkpark.PortableDoc.Render.compose_block/1.
  def build_block_patch(%{"type" => "heading"}, params) do
    %{}
    |> put_if_present("text", params["text"])
    |> put_if_present("level", parse_level(params["level"]))
  end

  def build_block_patch(%{"type" => "paragraph"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "callout"}, params) do
    %{}
    |> put_if_present("tone", params["tone"])
    # The fallback editor now owns the body through the rich WC. A chrome-only
    # form change therefore carries no `text` key and must not replace the
    # existing marked inline tree. Keep the explicit legacy text-param path so
    # older callers can still edit or clear a plain body.
    |> put_inline_text_if_present(params)
    |> put_callout_title(params["title"])
    # Unchecked checkbox sends no param → parse_bool(nil)=false (clears a prior
    # true so the toggle un-checks). Map.put = always-write semantics.
    |> Map.put("collapsible", parse_bool(params["collapsible"]))
    |> Map.put("collapsed", parse_bool(params["collapsed"]))
  end

  def build_block_patch(%{"type" => "code"}, params) do
    %{}
    |> put_if_present("lang", params["lang"])
    |> Map.put("value", params["value"] || "")
  end

  # diagram (barkpark-woxx): a Mermaid `source` textarea + an optional `caption`
  # input → the flat {source, caption} shape Render.compose_block/2 reads
  # (its `"diagram"` clause in `compose.ex`). Plain strings, no inline wrapping — the source is raw
  # Mermaid text and the caption is a short figure label.
  def build_block_patch(%{"type" => "diagram"}, params) do
    %{"source" => params["source"] || "", "caption" => params["caption"] || ""}
  end

  def build_block_patch(%{"type" => "route"} = block, params) do
    put_fetched_form_fields(
      %{},
      block,
      params,
      ~w(polyline sport distance elevation duration caption)
    )
  end

  def build_block_patch(%{"type" => "api-endpoint"} = block, params) do
    %{}
    |> put_fetched_form_fields(block, params, ~w(method path))
    |> put_api_endpoint_params(block, params)
  end

  def build_block_patch(%{"type" => "toc"} = block, params) do
    %{}
    |> put_positive_integer_form_field(block, params, "depth")
    |> put_strict_boolean_form_field(block, params, "numbered")
    |> put_strict_boolean_form_field(block, params, "sticky")
    |> put_toc_items(block, params)
  end

  def build_block_patch(%{"type" => "criteria-progress"} = block, params) do
    %{}
    |> put_fetched_form_fields(block, params, ~w(detail))
    |> put_criteria_progress_rows(block, params)
  end

  def build_block_patch(%{"type" => "gauge-list"} = block, params) do
    case gauge_list_patch(block, params) do
      {:ok, patch} -> patch
      {:error, _reason} -> %{}
    end
  end

  def build_block_patch(%{"type" => "steps"} = block, params) do
    case validate_steps_form(block, params) do
      {:ok, rows, submitted, action} -> build_steps_patch(block, rows, submitted, action, params)
      {:error, _reason} -> %{}
    end
  end

  # ── article-chrome blocks (barkpark-54kh) ──
  # eyebrow: single text input → flat "text" string (render reads `text`).
  def build_block_patch(%{"type" => "eyebrow"}, params) do
    %{"text" => params["text"] || ""}
  end

  # byline: single text input split on " · " → "items" list (render re-joins
  # the items with " · "). Blank/whitespace segments are dropped; an empty
  # input yields [].
  def build_block_patch(%{"type" => "byline"}, params) do
    items =
      (params["text"] || "")
      |> String.split("·")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{"items" => items}
  end

  # ingress / pullquote: a textarea → an inline "content" array, same MVP
  # plain-text-to-inline wrapping the paragraph/callout editors use.
  def build_block_patch(%{"type" => "ingress"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "pullquote"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "list"}, params) do
    # Each `item-N` param is one list item's plain text. Items keep their
    # 0-based order. An ordered/unordered toggle rides in `ordered`.
    items =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "item-") end)
      |> Enum.sort_by(fn {k, _v} -> k |> String.replace_prefix("item-", "") |> to_int(0) end)
      |> Enum.map(fn {_k, v} -> text_to_inline(v || "") end)

    %{}
    |> Map.put("items", items)
    |> put_if_present("ordered", parse_bool(params["ordered"]))
  end

  def build_block_patch(%{"type" => "section"}, params) do
    put_if_present(%{}, "title", params["title"])
  end

  def build_block_patch(%{"type" => "paper-links"} = block, params) do
    %{}
    |> put_optional_patch(params, "title")
    |> put_optional_patch(params, "description")
    |> put_optional_patch(params, "layout")
    |> put_paper_link_refs(block, params)
  end

  def build_block_patch(%{"type" => "expandable"}, params) do
    %{}
    |> put_param(params, "summary", "")
    |> Map.put("open", parse_bool(params["open"]))
  end

  def build_block_patch(%{"type" => "bar-chart"} = block, params) do
    %{}
    |> put_optional_number(params, "max")
    |> put_optional_patch(params, "title")
    |> Map.put("values", parse_bool(params["values"]))
    |> put_bar_chart_bars(block, params)
  end

  def build_block_patch(%{"type" => "field-number"} = block, params) do
    case validate_block_patch(block, params) do
      {:ok, patch} -> patch
      {:error, _reason} -> %{}
    end
  end

  def build_block_patch(%{"type" => "blockquote"} = block, params) do
    case Map.fetch(params, "cite") do
      {:ok, cite} -> blockquote_cite_patch(block, optional_string(cite))
      :error -> %{}
    end
  end

  def build_block_patch(%{"type" => "equation"}, params) do
    %{}
    |> put_param(params, "tex", "")
    |> Map.put("display", parse_bool(params["display"]))
  end

  def build_block_patch(%{"type" => "video"} = block, params) do
    %{}
    |> put_param(params, "src", "")
    |> put_param(params, "poster", "")
    |> Map.put("loop", parse_bool(params["loop"]))
    |> put_video_captions(block, params)
  end

  def build_block_patch(%{"type" => type} = block, params)
      when type in ["diff", "filetree", "footnote", "code-tabs"],
      do: TechnicalBlockEditor.build_patch(block, params)

  # Types authored through other editor paths do not use this form patch builder.
  def build_block_patch(_block, _params), do: %{}

  @doc false
  def validate_block_patch(%{"type" => "field-number"} = block, params) do
    with {:ok, value} <- parse_effective_number(block, params, "value"),
         {:ok, min} <- parse_effective_number(block, params, "min"),
         {:ok, max} <- parse_effective_number(block, params, "max"),
         {:ok, step} <- parse_effective_number(block, params, "step"),
         true <- is_nil(step) or step > 0,
         true <- is_nil(min) or is_nil(max) or min <= max,
         true <- is_nil(value) or is_nil(min) or value >= min,
         true <- is_nil(value) or is_nil(max) or value <= max do
      {:ok,
       %{}
       |> put_if_fetched(params, "label", "")
       |> put_if_fetched(params, "unit", "")
       |> put_if_parsed(params, "value", value)
       |> put_if_parsed(params, "min", min)
       |> put_if_parsed(params, "max", max)
       |> put_if_parsed(params, "step", step)}
    else
      _ -> {:error, :invalid_number}
    end
  end

  def validate_block_patch(%{"type" => "api-endpoint"} = block, params) do
    with :ok <- validate_collection_count(block, params, "params", "param") do
      {:ok, build_block_patch(block, params)}
    end
  end

  def validate_block_patch(%{"type" => "toc"} = block, params) do
    with :ok <- validate_collection_count(block, params, "items", "toc"),
         :ok <- validate_positive_integer_form_field(block, params, "depth", "depth"),
         :ok <- validate_boolean_form_fields(params, ~w(numbered sticky)),
         :ok <- validate_collection_text_fields(params, "toc", ~w(text anchor), "items"),
         :ok <- validate_toc_item_levels(block, params) do
      {:ok, build_block_patch(block, params)}
    end
  end

  def validate_block_patch(%{"type" => "criteria-progress"} = block, params) do
    with :ok <- validate_collection_count(block, params, "rows", "criterion"),
         :ok <- validate_text_form_fields(params, ~w(detail), "detail"),
         :ok <- validate_collection_text_fields(params, "criterion", ~w(label), "rows"),
         :ok <- validate_criteria_progress_numbers(block, params) do
      {:ok, build_block_patch(block, params)}
    end
  end

  def validate_block_patch(%{"type" => "gauge-list"} = block, params),
    do: gauge_list_patch(block, params)

  def validate_block_patch(%{"type" => "steps"} = block, params) do
    case validate_steps_form(block, params) do
      {:ok, rows, submitted, action} ->
        {:ok, build_steps_patch(block, rows, submitted, action, params)}

      {:error, _reason} = error ->
        error
    end
  end

  def validate_block_patch(%{"type" => type} = block, params)
      when type in ["diff", "filetree", "footnote", "code-tabs"],
      do: TechnicalBlockEditor.validate_patch(block, params)

  def validate_block_patch(block, params), do: {:ok, build_block_patch(block, params)}

  @doc false
  # A callout title is optional; an empty string drops it back to untitled.
  def put_callout_title(patch, title) when is_binary(title) do
    case String.trim(title) do
      "" -> Map.put(patch, "title", nil)
      t -> Map.put(patch, "title", t)
    end
  end

  def put_callout_title(patch, _), do: patch

  defp put_inline_text_if_present(patch, %{"text" => text}) when is_binary(text),
    do: Map.put(patch, "content", text_to_inline(text))

  defp put_inline_text_if_present(patch, _params), do: patch

  defp put_paper_link_refs(patch, block, %{"ref-count" => count} = params) do
    refs = Map.get(block, "refs", [])

    submitted_refs =
      count
      |> submitted_indices(length(refs))
      |> Enum.map(fn index ->
        refs
        |> Enum.at(index, "")
        |> paper_link_ref_from_params(params, index)
      end)
      |> apply_ref_action(params["ref-action"])

    Map.put(patch, "refs", submitted_refs)
  end

  defp put_paper_link_refs(patch, _block, _params), do: patch

  defp paper_link_ref_from_params(original, params, index) do
    prefix = "ref-#{index}-"
    row_submitted? = Enum.any?(Map.keys(params), &String.starts_with?(&1, prefix))

    if row_submitted? do
      slug = params[prefix <> "slug"] || paper_link_ref_field(original, "slug") || ""
      optional = ~w(title description eyebrow meta reason)

      authored =
        Enum.reduce(optional, paper_link_ref_map(original, slug), fn field, ref ->
          put_optional_param(ref, params, prefix <> field, field)
        end)
        |> Map.put("slug", slug)

      prefer_authored? = parse_bool(params[prefix <> "prefer-authored-copy"])

      # Older clients do not submit featured. Only an explicit field changes
      # it; the editor sends hidden false + checked true for deliberate clearing.
      authored =
        if Map.has_key?(params, prefix <> "featured"),
          do: Map.put(authored, "featured", parse_bool(params[prefix <> "featured"])),
          else: authored

      if is_binary(original) and not prefer_authored? and authored["featured"] != true and
           Enum.all?(optional, &(not Map.has_key?(authored, &1))) do
        slug
      else
        Map.put(authored, "prefer_authored_copy", prefer_authored?)
      end
    else
      original
    end
  end

  defp paper_link_ref_map(ref, _slug) when is_map(ref), do: ref
  defp paper_link_ref_map(_ref, slug), do: %{"slug" => slug}

  defp paper_link_ref_field(ref, "slug") when is_binary(ref), do: ref
  defp paper_link_ref_field(ref, key) when is_map(ref), do: Map.get(ref, key)
  defp paper_link_ref_field(_ref, _key), do: nil

  defp apply_ref_action(refs, "add"), do: refs ++ [""]

  defp apply_ref_action(refs, "remove:" <> index) do
    delete_at_valid_index(refs, index)
  end

  defp apply_ref_action(refs, _action), do: refs

  defp put_bar_chart_bars(patch, block, %{"bar-count" => count} = params) do
    bars = Map.get(block, "bars", [])

    submitted_bars =
      count
      |> submitted_indices(length(bars))
      |> Enum.map(fn index ->
        prefix = "bar-#{index}-"
        original = Enum.at(bars, index, %{})

        original
        |> ensure_map()
        |> put_param(params, prefix <> "label", "", "label")
        |> put_number_param(params, prefix <> "value", 0, "value")
      end)
      |> apply_bar_action(params["bar-action"])

    Map.put(patch, "bars", submitted_bars)
  end

  defp put_bar_chart_bars(patch, _block, _params), do: patch

  defp put_video_captions(patch, block, %{"caption-count" => count} = params) do
    captions = video_captions(block)

    if exact_submitted_count?(count, length(captions)) do
      submitted_captions =
        captions
        |> Enum.with_index()
        |> Enum.map(fn {original, index} ->
          prefix = "caption-#{index}-"

          if is_map(original) and Enum.any?(Map.keys(params), &String.starts_with?(&1, prefix)) do
            original
            |> put_param(params, prefix <> "lang", "", "lang")
            |> put_param(params, prefix <> "src", "", "src")
          else
            original
          end
        end)
        |> apply_caption_action(params["caption-action"])

      Map.put(patch, "captions", submitted_captions)
    else
      patch
    end
  end

  defp put_video_captions(patch, _block, _params), do: patch

  defp put_api_endpoint_params(patch, block, params) do
    count = params["param-count"]

    with {:ok, items} <- stored_collection(block, "params"),
         true <- exact_submitted_count?(count, length(items)) do
      updated =
        items
        |> Enum.with_index()
        |> Enum.map(fn
          {item, index} when is_map(item) -> update_api_endpoint_param(item, params, index)
          {item, _index} -> item
        end)
        |> apply_api_endpoint_param_action(params["param-action"])

      if updated == items, do: patch, else: Map.put(patch, "params", updated)
    else
      _ -> patch
    end
  end

  defp put_toc_items(patch, block, params) do
    put_editor_collection(
      patch,
      block,
      params,
      "items",
      "toc",
      &update_toc_item/3,
      %{"text" => "", "level" => 1, "anchor" => ""}
    )
  end

  defp update_toc_item(item, params, index) do
    prefix = "toc-#{index}-"

    item
    |> put_form_param_preserving_shape(params, prefix <> "text", "text")
    |> put_positive_integer_form_field(item, params, prefix <> "level", "level")
    |> put_form_param_preserving_shape(params, prefix <> "anchor", "anchor")
  end

  defp put_criteria_progress_rows(patch, block, params) do
    put_editor_collection(
      patch,
      block,
      params,
      "rows",
      "criterion",
      &update_criteria_progress_row/3,
      %{"label" => "", "met" => 0, "total" => 1}
    )
  end

  defp gauge_list_patch(block, params) do
    mode = gauge_list_mode(block)

    with :ok <- validate_text_form_fields(params, ~w(title), "title"),
         :ok <- validate_effective_option(params, "mode", mode, ~w(share count)),
         :ok <- validate_gauge_mode_fields(block, params, mode) do
      patch =
        %{}
        |> put_form_param_preserving_shape(block, params, "title", "title")
        |> put_effective_option(params, "mode", mode)

      {:ok, put_gauge_mode_fields(patch, block, params, mode)}
    end
  end

  defp validate_gauge_mode_fields(block, params, "share") do
    with false <- Map.has_key?(params, "groupBy"),
         :ok <- validate_optional_positive_number(block, params, "max"),
         :ok <- validate_gauge_rows(block, params) do
      :ok
    else
      true -> {:error, {:invalid_option, "groupBy"}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_gauge_mode_fields(block, params, "count") do
    if gauge_collection_params?(params) or Map.has_key?(params, "max") do
      {:error, {:malformed_collection, "rows"}}
    else
      validate_effective_option(
        params,
        "groupBy",
        gauge_list_group_by(block),
        ~w(worker phase status priority epic)
      )
    end
  end

  defp put_gauge_mode_fields(patch, block, params, "share") do
    patch
    |> put_optional_positive_number(block, params, "max")
    |> put_gauge_rows(block, params)
  end

  defp put_gauge_mode_fields(patch, block, params, "count") do
    put_effective_option(patch, params, "groupBy", gauge_list_group_by(block))
  end

  defp put_gauge_rows(patch, block, params) do
    put_editor_collection(
      patch,
      block,
      params,
      "rows",
      "gauge",
      &update_gauge_row/3,
      %{"label" => "", "value" => 0, "note" => ""}
    )
  end

  defp update_gauge_row(row, params, index) do
    prefix = "gauge-#{index}-"

    row
    |> put_form_param_preserving_shape(params, prefix <> "label", "label")
    |> put_number_form_field(row, params, prefix <> "value", "value")
    |> put_form_param_preserving_shape(params, prefix <> "note", "note")
  end

  defp validate_gauge_rows(block, params) do
    if gauge_collection_params?(params) do
      with {:ok, rows} <- stored_gauge_rows(block),
           true <- Enum.all?(rows, &is_map/1),
           true <- exact_submitted_count?(params["gauge-count"], length(rows)),
           :ok <- validate_gauge_param_names(params, length(rows)),
           :ok <- validate_gauge_action(params["gauge-action"], length(rows)),
           :ok <- validate_collection_text_fields(params, "gauge", ~w(label note), "rows"),
           :ok <- validate_collection_numbers(block, params, "rows", "gauge", ["value"], false) do
        :ok
      else
        {:error, _reason} = error -> error
        _ -> {:error, {:malformed_collection, "rows"}}
      end
    else
      :ok
    end
  end

  defp stored_gauge_rows(block) do
    case Map.fetch(block, "rows") do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      _other -> {:error, {:malformed_collection, "rows"}}
    end
  end

  defp gauge_collection_params?(params) do
    Enum.any?(Map.keys(params), &(is_binary(&1) and String.starts_with?(&1, "gauge-")))
  end

  defp validate_gauge_param_names(params, count) do
    allowed =
      MapSet.new(~w(gauge-count gauge-action))
      |> then(fn allowed ->
        if count == 0 do
          allowed
        else
          Enum.reduce(0..(count - 1), allowed, fn index, acc ->
            Enum.reduce(~w(label value note), acc, fn field, fields ->
              MapSet.put(fields, "gauge-#{index}-#{field}")
            end)
          end)
        end
      end)

    unexpected? =
      Enum.any?(Map.keys(params), fn key ->
        is_binary(key) and String.starts_with?(key, "gauge-") and
          not MapSet.member?(allowed, key)
      end)

    if unexpected?, do: {:error, {:malformed_collection, "rows"}}, else: :ok
  end

  defp validate_gauge_action(nil, _count), do: :ok
  defp validate_gauge_action("", _count), do: :ok
  defp validate_gauge_action("add", _count), do: :ok

  defp validate_gauge_action(action, count) when is_binary(action) do
    case String.split(action, ":", parts: 2) do
      [kind, index] when kind in ~w(remove up down) ->
        case Integer.parse(index) do
          {index, ""} when index >= 0 and index < count -> :ok
          _ -> {:error, {:malformed_collection, "rows"}}
        end

      _ ->
        {:error, {:malformed_collection, "rows"}}
    end
  end

  defp validate_gauge_action(_action, _count), do: {:error, {:malformed_collection, "rows"}}

  defp validate_optional_positive_number(block, params, field) do
    if not Map.has_key?(params, field) or form_wire_value(Map.get(block, field)) == params[field] or
         params[field] == "" or valid_positive_number?(params[field]) do
      :ok
    else
      {:error, {:invalid_number, field}}
    end
  end

  defp valid_positive_number?(value) do
    case parse_submitted_number(value) do
      {:ok, number} when is_number(number) and number > 0 -> true
      _ -> false
    end
  end

  defp put_optional_positive_number(patch, block, params, field) do
    cond do
      not Map.has_key?(params, field) ->
        patch

      form_wire_value(Map.get(block, field)) == params[field] ->
        patch

      params[field] == "" ->
        Map.put(patch, field, nil)

      true ->
        {:ok, number} = parse_submitted_number(params[field])
        Map.put(patch, field, number)
    end
  end

  defp validate_effective_option(params, field, effective, allowed) do
    case Map.fetch(params, field) do
      :error -> :ok
      {:ok, ^effective} -> :ok
      {:ok, value} -> if(value in allowed, do: :ok, else: {:error, {:invalid_option, field}})
    end
  end

  defp put_effective_option(patch, params, field, effective) do
    case Map.fetch(params, field) do
      {:ok, value} when value != effective -> Map.put(patch, field, value)
      _ -> patch
    end
  end

  defp update_criteria_progress_row(item, params, index) do
    prefix = "criterion-#{index}-"

    item
    |> put_form_param_preserving_shape(params, prefix <> "label", "label")
    |> put_number_form_field(item, params, prefix <> "met", "met")
    |> put_number_form_field(item, params, prefix <> "total", "total")
  end

  defp validate_steps_form(block, params) do
    if step_form_params?(params) do
      with {:ok, rows} <- stored_steps_rows(block),
           true <- Enum.all?(rows, &valid_step_row?/1),
           true <- unique_step_row_ids?(rows),
           true <- exact_submitted_count?(params["step-count"], length(rows)),
           :ok <- validate_step_param_names(params, length(rows)),
           {:ok, submitted} <- submitted_step_rows(params, rows),
           true <- Enum.map(submitted, &elem(&1, 0)) == Enum.map(rows, &Map.fetch!(&1, "id")),
           {:ok, action} <- validate_step_action(params["step-action"], block, rows, params) do
        {:ok, rows, submitted, action}
      else
        {:error, _reason} = error -> error
        _ -> {:error, {:malformed_collection, "steps"}}
      end
    else
      {:ok, [], [], nil}
    end
  end

  defp build_steps_patch(_block, [], [], nil, _params), do: %{}

  defp build_steps_patch(_block, rows, submitted, action, params) do
    titled =
      Enum.zip(rows, submitted)
      |> Enum.map(fn {row, {_id, title}} ->
        put_form_param_preserving_shape(row, %{"title" => title}, "title", "title")
      end)

    updated = apply_step_action(titled, action, params)
    if updated == rows, do: %{}, else: %{"steps" => updated}
  end

  defp step_form_params?(params) do
    Enum.any?(Map.keys(params), &(is_binary(&1) and String.starts_with?(&1, "step-")))
  end

  defp stored_steps_rows(block) do
    case Map.fetch(block, "steps") do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      _ -> {:error, {:malformed_collection, "steps"}}
    end
  end

  defp valid_step_row?(%{"id" => id}) when is_binary(id) and id != "", do: true
  defp valid_step_row?(_row), do: false

  defp unique_step_row_ids?(rows) do
    ids = Enum.map(rows, &Map.fetch!(&1, "id"))
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp validate_step_param_names(params, count) do
    allowed =
      MapSet.new(~w(step-count step-action step-new-row-id step-new-child-id))
      |> then(fn allowed ->
        if count == 0 do
          allowed
        else
          Enum.reduce(0..(count - 1), allowed, fn index, acc ->
            acc
            |> MapSet.put("step-#{index}-id")
            |> MapSet.put("step-#{index}-title")
          end)
        end
      end)

    unexpected? =
      Enum.any?(Map.keys(params), fn key ->
        is_binary(key) and String.starts_with?(key, "step-") and not MapSet.member?(allowed, key)
      end)

    if unexpected?, do: {:error, {:malformed_collection, "steps"}}, else: :ok
  end

  defp submitted_step_rows(params, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {_row, index}, {:ok, acc} ->
      id_key = "step-#{index}-id"
      title_key = "step-#{index}-title"

      case {Map.fetch(params, id_key), Map.fetch(params, title_key)} do
        {{:ok, id}, {:ok, title}} when is_binary(id) and is_binary(title) ->
          {:cont, {:ok, [{id, title} | acc]}}

        _ ->
          {:halt, {:error, {:malformed_collection, "steps"}}}
      end
    end)
    |> case do
      {:ok, submitted} -> {:ok, Enum.reverse(submitted)}
      error -> error
    end
  end

  defp validate_step_action(action, _block, _rows, _params) when action in [nil, ""],
    do: {:ok, nil}

  defp validate_step_action("add", block, _rows, params) do
    case validate_new_step_id(params["step-new-row-id"], block) do
      :ok -> {:ok, :add}
      {:error, _reason} = error -> error
    end
  end

  defp validate_step_action("remove:" <> id, _block, rows, _params) do
    with {:ok, {:remove, ^id}} <- validate_existing_step_action(:remove, id, rows),
         %{} = row <- Enum.find(rows, &(Map.get(&1, "id") == id)),
         nil <- locked_step_descendant_id(row) do
      {:ok, {:remove, id}}
    else
      locked_id when is_binary(locked_id) ->
        {:error, {:locked_block, locked_id, "remove-block"}}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, {:malformed_collection, "steps"}}
    end
  end

  defp validate_step_action("up:" <> id, _block, rows, _params),
    do: validate_existing_step_action(:up, id, rows)

  defp validate_step_action("down:" <> id, _block, rows, _params),
    do: validate_existing_step_action(:down, id, rows)

  defp validate_step_action("add-body:" <> id, block, rows, params) do
    with {:ok, {:add_body, ^id}} <- validate_existing_step_action(:add_body, id, rows),
         :ok <- validate_new_step_id(params["step-new-child-id"], block),
         %{} = row <- Enum.find(rows, &(Map.get(&1, "id") == id)),
         {:ok, _updated} <- add_first_step_body(row, params["step-new-child-id"]) do
      {:ok, {:add_body, id}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:malformed_collection, "steps"}}
    end
  end

  defp validate_step_action(_action, _block, _rows, _params),
    do: {:error, {:malformed_collection, "steps"}}

  defp validate_existing_step_action(kind, id, rows) do
    if is_binary(id) and Enum.any?(rows, &(Map.get(&1, "id") == id)),
      do: {:ok, {kind, id}},
      else: {:error, {:malformed_collection, "steps"}}
  end

  defp apply_step_action(rows, nil, _params), do: rows

  defp apply_step_action(rows, :add, params) do
    id = params["step-new-row-id"]
    rows ++ [%{"id" => id, "title" => "", "blocks" => []}]
  end

  defp apply_step_action(rows, {:remove, id}, _params) do
    Enum.reject(rows, &(Map.get(&1, "id") == id))
  end

  defp apply_step_action(rows, {direction, id}, _params) when direction in [:up, :down] do
    index = Enum.find_index(rows, &(Map.get(&1, "id") == id))
    offset = if direction == :up, do: -1, else: 1
    move_at_index(rows, index, offset)
  end

  defp apply_step_action(rows, {:add_body, id}, params) do
    child_id = params["step-new-child-id"]
    index = Enum.find_index(rows, &(Map.get(&1, "id") == id))
    {:ok, row} = add_first_step_body(Enum.at(rows, index), child_id)
    List.replace_at(rows, index, row)
  end

  defp validate_new_step_id(id, block) when is_binary(id) do
    cond do
      String.trim(id) == "" -> {:error, {:malformed_collection, "steps"}}
      MapSet.member?(step_tree_ids(block), id) -> {:error, {:duplicate_id, id}}
      true -> :ok
    end
  end

  defp validate_new_step_id(_id, _block), do: {:error, {:malformed_collection, "steps"}}

  defp step_tree_ids(value), do: collect_step_ids(value, MapSet.new())

  defp collect_step_ids(values, ids) when is_list(values),
    do: Enum.reduce(values, ids, &collect_step_ids/2)

  defp collect_step_ids(%{} = value, ids) do
    ids =
      case Map.get(value, "id") do
        id when is_binary(id) and id != "" -> MapSet.put(ids, id)
        _ -> ids
      end

    ids = collect_step_ids(Map.get(value, "children"), ids)
    ids = collect_step_ids(Map.get(value, "blocks"), ids)
    collect_step_ids(Map.get(value, "steps"), ids)
  end

  defp collect_step_ids(_value, ids), do: ids

  defp locked_step_descendant_id(%{"locked" => true} = value), do: Map.get(value, "id") || ""

  defp locked_step_descendant_id(%{} = value) do
    Enum.find_value(~w(children blocks steps), fn key ->
      locked_step_descendant_id(Map.get(value, key))
    end)
  end

  defp locked_step_descendant_id(values) when is_list(values),
    do: Enum.find_value(values, &locked_step_descendant_id/1)

  defp locked_step_descendant_id(_value), do: nil

  defp add_first_step_body(row, child_id) do
    child = default_block("paragraph", child_id)

    case Map.get(row, "children") do
      children when is_list(children) ->
        if children == [], do: {:ok, Map.put(row, "children", [child])}, else: malformed_steps()

      children when children in [nil, false] ->
        case Map.get(row, "blocks") do
          blocks when is_list(blocks) ->
            if blocks == [], do: {:ok, Map.put(row, "blocks", [child])}, else: malformed_steps()

          blocks when blocks in [nil, false] ->
            {:ok, Map.put(row, "blocks", [child])}

          _ ->
            malformed_steps()
        end

      _ ->
        malformed_steps()
    end
  end

  defp malformed_steps, do: {:error, {:malformed_collection, "steps"}}

  defp move_at_index(items, index, offset) when is_integer(index) do
    target = index + offset

    if target >= 0 and target < length(items) do
      source_item = Enum.at(items, index)
      target_item = Enum.at(items, target)

      items
      |> List.replace_at(index, target_item)
      |> List.replace_at(target, source_item)
    else
      items
    end
  end

  defp put_editor_collection(patch, block, params, field, prefix, update, default) do
    count = params[prefix <> "-count"]

    with {:ok, items} <- stored_collection(block, field),
         true <- exact_submitted_count?(count, length(items)) do
      updated =
        items
        |> Enum.with_index()
        |> Enum.map(fn
          {item, index} when is_map(item) -> update.(item, params, index)
          {item, _index} -> item
        end)
        |> apply_collection_action(params[prefix <> "-action"], default)

      if updated == items, do: patch, else: Map.put(patch, field, updated)
    else
      _ -> patch
    end
  end

  defp apply_collection_action(items, "add", default), do: items ++ [default]

  defp apply_collection_action(items, "remove:" <> index, _default),
    do: delete_at_valid_index(items, index)

  defp apply_collection_action(items, "up:" <> index, _default), do: move_at(items, index, -1)
  defp apply_collection_action(items, "down:" <> index, _default), do: move_at(items, index, 1)
  defp apply_collection_action(items, _action, _default), do: items

  defp update_api_endpoint_param(item, params, index) do
    prefix = "param-#{index}-"

    item
    |> put_form_param_preserving_shape(params, prefix <> "name", "name")
    |> put_form_param_preserving_shape(params, prefix <> "in", "in")
    |> put_form_param_preserving_shape(params, prefix <> "type", "type")
    |> put_required_param(params, prefix <> "required")
  end

  defp put_required_param(item, params, param) do
    if Map.has_key?(params, param) do
      submitted = parse_bool(params[param])

      if api_endpoint_param_required?(item) == submitted,
        do: item,
        else: Map.put(item, "required", submitted)
    else
      item
    end
  end

  defp apply_api_endpoint_param_action(items, "add") do
    items ++ [%{"name" => "", "in" => "query", "type" => "string", "required" => false}]
  end

  defp apply_api_endpoint_param_action(items, "remove:" <> index),
    do: delete_at_valid_index(items, index)

  defp apply_api_endpoint_param_action(items, "up:" <> index), do: move_at(items, index, -1)
  defp apply_api_endpoint_param_action(items, "down:" <> index), do: move_at(items, index, 1)

  defp apply_api_endpoint_param_action(items, _action), do: items

  defp apply_bar_action(bars, "add"), do: bars ++ [%{"label" => "", "value" => 0}]

  defp apply_bar_action(bars, "remove:" <> index) do
    delete_at_valid_index(bars, index)
  end

  defp apply_bar_action(bars, _action), do: bars

  defp apply_caption_action(captions, "add"),
    do: captions ++ [%{"lang" => "", "src" => ""}]

  defp apply_caption_action(captions, "remove:" <> index),
    do: delete_at_valid_index(captions, index)

  defp apply_caption_action(captions, _action), do: captions

  defp submitted_indices(count, existing_count) do
    case count |> to_int(0) |> max(0) |> min(existing_count) do
      0 -> []
      count -> 0..(count - 1)
    end
  end

  defp exact_submitted_count?(count, expected) when is_binary(count) do
    case Integer.parse(count) do
      {^expected, ""} -> true
      _ -> false
    end
  end

  defp exact_submitted_count?(_count, _expected), do: false

  defp validate_collection_count(block, params, field_name, param_name) do
    count_name = param_name <> "-count"

    collection_params? =
      Enum.any?(Map.keys(params), fn key ->
        is_binary(key) and String.starts_with?(key, param_name <> "-")
      end)

    cond do
      not Map.has_key?(params, count_name) and not collection_params? ->
        :ok

      not Map.has_key?(params, count_name) ->
        {:error, {:malformed_collection, field_name}}

      true ->
        with {:ok, items} <- stored_collection(block, field_name),
             true <- exact_submitted_count?(params[count_name], length(items)) do
          :ok
        else
          _ -> {:error, {:malformed_collection, field_name}}
        end
    end
  end

  defp validate_toc_item_levels(block, params) do
    validate_collection_numbers(block, params, "items", "toc", ["level"], true)
  end

  defp validate_criteria_progress_numbers(block, params) do
    validate_collection_numbers(block, params, "rows", "criterion", ["met", "total"], false)
  end

  defp validate_collection_numbers(block, params, field, prefix, keys, positive?) do
    with {:ok, items} <- stored_collection(block, field) do
      items
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn
        {item, index}, :ok when is_map(item) ->
          valid? =
            Enum.all?(keys, fn key ->
              param = "#{prefix}-#{index}-#{key}"

              not Map.has_key?(params, param) or
                form_wire_value(Map.get(item, key)) == params[param] or
                valid_submitted_number?(params[param], positive?)
            end)

          if valid?, do: {:cont, :ok}, else: {:halt, {:error, {:invalid_number, field}}}

        {_item, _index}, :ok ->
          {:cont, :ok}
      end)
    end
  end

  defp validate_positive_integer_form_field(block, params, field, error_field) do
    if not Map.has_key?(params, field) or form_wire_value(Map.get(block, field)) == params[field] or
         valid_submitted_number?(params[field], true) do
      :ok
    else
      {:error, {:invalid_number, error_field}}
    end
  end

  defp validate_text_form_fields(params, fields, error_field) do
    if Enum.all?(fields, fn field ->
         not Map.has_key?(params, field) or is_binary(params[field])
       end) do
      :ok
    else
      {:error, {:invalid_text, error_field}}
    end
  end

  defp validate_boolean_form_fields(params, fields) do
    case Enum.find(fields, fn field ->
           Map.has_key?(params, field) and params[field] not in ["true", "false", true, false]
         end) do
      nil -> :ok
      field -> {:error, {:invalid_boolean, field}}
    end
  end

  defp validate_collection_text_fields(params, prefix, fields, error_field) do
    malformed? =
      Enum.any?(params, fn
        {param, value} when is_binary(param) ->
          collection_text_param?(param, prefix, fields) and not is_binary(value)

        {_param, _value} ->
          false
      end)

    if malformed?, do: {:error, {:invalid_text, error_field}}, else: :ok
  end

  defp collection_text_param?(param, prefix, fields) do
    Enum.any?(fields, fn field ->
      start = prefix <> "-"
      suffix = "-" <> field

      if String.starts_with?(param, start) and String.ends_with?(param, suffix) do
        index_size = byte_size(param) - byte_size(start) - byte_size(suffix)

        index_size > 0 and
          case param |> binary_part(byte_size(start), index_size) |> Integer.parse() do
            {index, ""} when index >= 0 -> true
            _ -> false
          end
      else
        false
      end
    end)
  end

  defp valid_submitted_number?(value, positive?) do
    case parse_submitted_number(value) do
      {:ok, number} when is_number(number) -> not positive? or (is_integer(number) and number > 0)
      _ -> false
    end
  end

  defp stored_collection(block, key) do
    case Map.fetch(block, key) do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, item} -> {:ok, [item]}
    end
  end

  defp delete_at_valid_index(items, index) do
    case Integer.parse(index) do
      {index, ""} when index >= 0 and index < length(items) -> List.delete_at(items, index)
      _ -> items
    end
  end

  defp move_at(items, index, offset) do
    with {index, ""} <- Integer.parse(index),
         target = index + offset,
         true <- index >= 0 and index < length(items),
         true <- target >= 0 and target < length(items) do
      source_item = Enum.at(items, index)
      target_item = Enum.at(items, target)

      items
      |> List.replace_at(index, target_item)
      |> List.replace_at(target, source_item)
    else
      _ -> items
    end
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp put_param(map, params, param, default) do
    if Map.has_key?(params, param), do: Map.put(map, param, params[param] || default), else: map
  end

  defp put_param(map, params, param, default, key) do
    if Map.has_key?(params, param), do: Map.put(map, key, params[param] || default), else: map
  end

  defp put_number_param(map, params, param, default, key) do
    if Map.has_key?(params, param) do
      Map.put(map, key, parse_number(params[param], default))
    else
      map
    end
  end

  defp put_if_fetched(map, params, key, default) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(map, key, value || default)
      :error -> map
    end
  end

  defp put_if_parsed(map, params, key, value) do
    if Map.has_key?(params, key), do: Map.put(map, key, value), else: map
  end

  defp put_optional_number(map, params, key) do
    if Map.has_key?(params, key) do
      case params[key] do
        value when value in [nil, ""] -> Map.put(map, key, nil)
        value -> Map.put(map, key, parse_number(value, Map.get(map, key)))
      end
    else
      map
    end
  end

  defp parse_number(value, _default) when is_integer(value) or is_float(value), do: value

  defp parse_number(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} ->
        number

      _ ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> default
        end
    end
  end

  defp parse_number(_value, default), do: default

  defp parse_submitted_number(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_submitted_number(value) when is_integer(value) or is_float(value), do: {:ok, value}

  defp parse_submitted_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {number, ""} ->
        {:ok, number}

      _ ->
        case Float.parse(trimmed) do
          {number, ""} -> {:ok, number}
          _ -> :error
        end
    end
  end

  defp parse_submitted_number(_value), do: :error

  defp parse_number_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> parse_submitted_number(value)
      :error -> {:ok, nil}
    end
  end

  defp parse_effective_number(block, params, key) do
    if Map.has_key?(params, key) do
      parse_number_param(params, key)
    else
      parse_submitted_number(Map.get(block, key))
    end
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp put_optional_patch(map, params, key) do
    if Map.has_key?(params, key) do
      case params[key] do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> Map.put(map, key, nil)
            trimmed -> Map.put(map, key, trimmed)
          end

        _ ->
          Map.put(map, key, nil)
      end
    else
      map
    end
  end

  defp put_optional_param(map, params, param, key) do
    if Map.has_key?(params, param) do
      case params[param] do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> Map.delete(map, key)
            trimmed -> Map.put(map, key, trimmed)
          end

        _ ->
          Map.delete(map, key)
      end
    else
      map
    end
  end

  @doc false
  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, _key, ""), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  def parse_level(nil), do: nil

  def parse_level(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n in 1..6 -> n
      _ -> nil
    end
  end

  def parse_level(_), do: nil

  @doc false
  def parse_bool("true"), do: true
  def parse_bool("on"), do: true
  def parse_bool(true), do: true
  def parse_bool(_), do: false

  @doc false
  def to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  def to_int(_, default), do: default

  @doc false
  # Legacy inline handling: wrap an explicitly submitted plain-text body as a
  # single text inline node. Current rich-body UI paths use the WC and submit
  # canonical inline trees directly; this remains for older form callers.
  def text_to_inline(text) when is_binary(text) do
    [%{"type" => "text", "value" => text}]
  end

  @doc false
  # Render an InlineNode array back to plain text for a textarea/input: keep
  # only text-node values (and nested children of strong/em/link), concatenated.
  # Lossy by design — the inverse of text_to_inline/1 for the MVP.
  def inline_to_text(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&inline_node_text/1)
    |> Enum.join("")
  end

  def inline_to_text(_), do: ""

  @doc false
  def inline_node_text(%{"type" => "text", "value" => v}) when is_binary(v), do: v
  def inline_node_text(%{"value" => v}) when is_binary(v), do: v

  def inline_node_text(%{"children" => children}) when is_list(children),
    do: inline_to_text(children)

  def inline_node_text(s) when is_binary(s), do: s
  def inline_node_text(_), do: ""

  @doc false
  # Generate a short unique, immutable block id. Block ids are never reused or
  # mutated once assigned (patch.ex locks `id`).
  def new_block_id do
    "b-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end

  # Resolve visible block bodies; step rows are containers, not block targets.
  @doc false
  def find_paper_block(blocks, id) when is_list(blocks) do
    Enum.find_value(blocks, fn
      b when is_map(b) ->
        cond do
          Map.get(b, "id") == id ->
            b

          Map.get(b, "type") in ["section", "expandable"] ->
            find_paper_block(container_children(b), id)

          Map.get(b, "type") == "steps" and is_list(b["steps"]) ->
            Enum.find_value(b["steps"], fn
              row when is_map(row) -> find_paper_block(visible_body_children(row), id)
              _ -> nil
            end)

          true ->
            nil
        end

      _ ->
        nil
    end)
  end

  def find_paper_block(_blocks, _id), do: nil

  @doc false
  def container_children(%{"type" => "expandable"} = block), do: visible_body_children(block)

  def container_children(%{"blocks" => blocks}) when is_list(blocks), do: blocks
  def container_children(_block), do: []

  defp visible_body_children(%{"children" => children}) when is_list(children), do: children
  defp visible_body_children(%{"children" => children}) when children not in [nil, false], do: []
  defp visible_body_children(%{"blocks" => blocks}) when is_list(blocks), do: blocks
  defp visible_body_children(_block), do: []

  @doc false
  def canvas_run_context(params) when is_map(params) do
    keys = ~w(container_kind container_id container_row_id container_run_ids)

    if Enum.any?(keys, &Map.has_key?(params, &1)) do
      raw =
        keys
        |> Enum.reduce(%{}, fn key, context ->
          case Map.fetch(params, key) do
            {:ok, value} -> Map.put(context, key, value)
            :error -> context
          end
        end)
        |> Map.update("container_id", nil, fn
          id when is_binary(id) -> String.trim(id)
          id -> id
        end)

      case CanvasRunContext.normalize(raw) do
        {:ok, context} when is_map(context) -> {:ok, context}
        _invalid -> {:error, :invalid_container_context}
      end
    else
      {:ok, nil}
    end
  end

  def canvas_run_context(_params), do: {:error, :invalid_container_context}

  @doc false
  def paper_link_ref_value(ref, "slug") when is_binary(ref), do: ref
  def paper_link_ref_value(ref, key) when is_map(ref), do: Map.get(ref, key)
  def paper_link_ref_value(_ref, _key), do: nil

  @doc false
  def blockquote_cite_value(block) when is_map(block) do
    Map.get(block, "cite") || Map.get(block, "attribution") || ""
  end

  @doc false
  def video_caption_value(caption, key) when is_map(caption), do: Map.get(caption, key, "")
  def video_caption_value(_caption, _key), do: ""

  @doc false
  def video_captions(block) when is_map(block) do
    case Map.get(block, "captions") do
      captions when is_list(captions) -> captions
      _ -> []
    end
  end

  @doc false
  def api_endpoint_params(block) when is_map(block) do
    case Map.get(block, "params") do
      nil -> []
      params when is_list(params) -> params
      param -> [param]
    end
  end

  @doc false
  def api_endpoint_param_value(param, key) when is_map(param), do: form_value(Map.get(param, key))
  def api_endpoint_param_value(_param, _key), do: ""

  @doc false
  def api_endpoint_param_required?(param) when is_map(param),
    do: truthy_string?(Map.get(param, "required"))

  def api_endpoint_param_required?(_param), do: false

  @doc false
  def toc_items(block) when is_map(block), do: collection_form_items(block, "items")

  @doc false
  def criteria_progress_rows(block) when is_map(block), do: collection_form_items(block, "rows")

  @doc false
  def gauge_list_mode(block) when is_map(block) do
    case effective_trimmed_string(Map.get(block, "mode")) |> String.downcase() do
      mode when mode in ~w(share count) ->
        mode

      _other ->
        if Map.has_key?(block, "rows") and not Map.has_key?(block, "snapshot"),
          do: "share",
          else: "count"
    end
  end

  def gauge_list_mode(_block), do: "count"

  @doc false
  def gauge_list_rows(block) when is_map(block), do: collection_form_items(block, "rows")
  def gauge_list_rows(_block), do: []

  @doc false
  def strict_boolean_field?(block, field) when is_map(block), do: strict_true?(block, field)

  defp collection_form_items(block, field) do
    case Map.get(block, field) do
      nil -> []
      items when is_list(items) -> items
      item -> [item]
    end
  end

  @doc false
  def form_value(value) when is_binary(value) or is_number(value), do: value
  def form_value(_value), do: ""

  defp truthy_string?(true), do: true

  defp truthy_string?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) == "true"

  defp truthy_string?(_value), do: false

  @doc false
  def gauge_list_group_by(block) when is_map(block) do
    case effective_trimmed_string(Map.get(block, "groupBy")) do
      "" -> "status"
      group_by -> group_by
    end
  end

  def gauge_list_group_by(_block), do: "status"

  defp effective_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp effective_trimmed_string(value) when is_integer(value), do: Integer.to_string(value)
  defp effective_trimmed_string(value) when is_float(value), do: Float.to_string(value)
  defp effective_trimmed_string(_value), do: ""

  defp put_fetched_form_fields(map, block, params, fields) do
    Enum.reduce(fields, map, fn field, acc ->
      put_form_param_preserving_shape(acc, block, params, field, field)
    end)
  end

  defp put_strict_boolean_form_field(map, block, params, field) do
    if Map.has_key?(params, field) do
      submitted = parse_bool(params[field])

      if strict_true?(block, field) == submitted,
        do: map,
        else: Map.put(map, field, submitted)
    else
      map
    end
  end

  defp put_positive_integer_form_field(map, block, params, field) do
    put_positive_integer_form_field(map, block, params, field, field)
  end

  defp put_positive_integer_form_field(map, block, params, param, field) do
    put_parsed_form_number(map, block, params, param, field, true)
  end

  defp put_number_form_field(map, block, params, param, field) do
    put_parsed_form_number(map, block, params, param, field, false)
  end

  defp put_parsed_form_number(map, block, params, param, field, positive?) do
    cond do
      not Map.has_key?(params, param) ->
        map

      form_wire_value(Map.get(block, field)) == params[param] ->
        map

      true ->
        case parse_submitted_number(params[param]) do
          {:ok, number}
          when is_number(number) and (not positive? or (is_integer(number) and number > 0)) ->
            Map.put(map, field, number)

          _ ->
            map
        end
    end
  end

  defp put_form_param_preserving_shape(item, params, param, field) do
    put_form_param_preserving_shape(item, item, params, param, field)
  end

  defp put_form_param_preserving_shape(map, original, params, param, field) do
    if Map.has_key?(params, param) and form_wire_value(Map.get(original, field)) != params[param],
      do: Map.put(map, field, params[param] || ""),
      else: map
  end

  defp form_wire_value(value) when is_binary(value), do: value
  defp form_wire_value(value) when is_integer(value), do: Integer.to_string(value)
  defp form_wire_value(value) when is_float(value), do: Float.to_string(value)
  defp form_wire_value(_value), do: ""

  defp strict_true?(block, field), do: Map.get(block, field) == true

  defp blockquote_cite_patch(block, cite) do
    cond do
      Map.has_key?(block, "cite") and Map.has_key?(block, "attribution") ->
        %{"cite" => cite, "attribution" => nil}

      Map.has_key?(block, "attribution") ->
        %{"attribution" => cite}

      true ->
        %{"cite" => cite}
    end
  end

  @doc false
  # A fresh block of `type` with sensible empty defaults, in the EXACT shape
  # Render.compose_block/1 (and, for field/composite blocks, the field-block
  # editors) expect. Every type the add-block menu offers (P3.1) has a clause
  # here producing a minimal, VALID, immediately-editable block — the new id is
  # the only non-default datum. The configurable types (select / composite /
  # arrayOf / codelist / localizedText) get a minimal usable shape; real schema
  # config (option lists, subfield trees, the bound codelist, language set)
  # lands later via the Expectations layer — there is no config editor here.
  #
  # ── rich-text (Text group) ──
  def default_block("heading", id),
    do: %{"id" => id, "type" => "heading", "text" => "New heading", "level" => 2}

  def default_block("paragraph", id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}

  def default_block("list", id),
    do: %{
      "id" => id,
      "type" => "list",
      "ordered" => false,
      "items" => [[%{"type" => "text", "value" => ""}]]
    }

  def default_block("callout", id),
    do: %{
      "id" => id,
      "type" => "callout",
      "tone" => "info",
      "content" => [%{"type" => "text", "value" => ""}]
    }

  def default_block("code", id),
    do: %{"id" => id, "type" => "code", "lang" => "", "value" => ""}

  # ── visual blocks ──
  # diagram (barkpark-woxx): a Mermaid block. `source` is raw Mermaid text,
  # `caption` an optional figure label — the exact flat shape
  # Render.compose_block/2 reads (its `"diagram"` clause in `compose.ex`).
  # Empty defaults are valid: an
  # empty `source` renders an empty `<pre class="mermaid">`.
  def default_block("diagram", id),
    do: %{"id" => id, "type" => "diagram", "source" => "", "caption" => ""}

  def default_block("equation", id),
    do: %{"id" => id, "type" => "equation", "tex" => "", "display" => true}

  def default_block("route", id),
    do: %{
      "id" => id,
      "type" => "route",
      "polyline" => "",
      "sport" => "",
      "distance" => "",
      "elevation" => "",
      "duration" => "",
      "caption" => ""
    }

  def default_block("toc", id),
    do: %{
      "id" => id,
      "type" => "toc",
      "items" => [],
      "depth" => 2,
      "numbered" => false,
      "sticky" => false
    }

  def default_block("criteria-progress", id),
    do: %{
      "id" => id,
      "type" => "criteria-progress",
      "rows" => [],
      "detail" => "rows"
    }

  def default_block("gauge-list", id),
    do: %{
      "id" => id,
      "type" => "gauge-list",
      "title" => "",
      "mode" => "share",
      "rows" => [%{"label" => "", "value" => 0, "note" => ""}]
    }

  def default_block("steps", id) do
    row_id = id <> "-step-0"

    %{
      "id" => id,
      "type" => "steps",
      "steps" => [
        %{
          "id" => row_id,
          "title" => "Step 1",
          "blocks" => [default_block("paragraph", row_id <> "-0")]
        }
      ]
    }
  end

  def default_block("diff", id),
    do: %{"id" => id, "type" => "diff", "diff" => "", "file" => "", "lang" => ""}

  def default_block("filetree", id),
    do: %{"id" => id, "type" => "filetree", "text" => "", "legend" => ""}

  def default_block("footnote", id),
    do: %{"id" => id, "type" => "footnote", "notes" => []}

  def default_block("code-tabs", id),
    do: %{"id" => id, "type" => "code-tabs", "tabs" => [], "syncKey" => ""}

  def default_block("api-endpoint", id),
    do: %{"id" => id, "type" => "api-endpoint", "method" => "", "path" => "", "params" => []}

  def default_block("video", id),
    do: %{"id" => id, "type" => "video", "src" => "", "poster" => "", "captions" => []}

  # ── article-chrome blocks (render-only until now; barkpark-54kh) ──
  # These mirror the Render.compose_block/2 shapes verbatim (render.ex):
  #   eyebrow   → flat "text" string
  #   byline    → "items" list (render joins with " · ")
  #   ingress   → inline "content" array
  #   pullquote → inline "content" array (rendered italic)
  def default_block("eyebrow", id),
    do: %{"id" => id, "type" => "eyebrow", "text" => ""}

  def default_block("byline", id),
    do: %{"id" => id, "type" => "byline", "items" => []}

  def default_block("ingress", id),
    do: %{"id" => id, "type" => "ingress", "content" => []}

  def default_block("pullquote", id),
    do: %{"id" => id, "type" => "pullquote", "content" => []}

  def default_block("blockquote", id),
    do: %{"id" => id, "type" => "blockquote", "content" => [], "cite" => nil}

  def default_block("divider", id),
    do: %{"id" => id, "type" => "divider"}

  def default_block("section", id),
    do: %{"id" => id, "type" => "section", "title" => "New section", "blocks" => []}

  # ── canvas-insertable structural blocks (block-insertability) ──
  # These mirror the canvas slash-menu defaults (slash-insert.js canvasDefaultBlock) so
  # the LiveView add-block path and the canvas "/" pick build the SAME minimal block.
  # Each shape matches the Render.Compose.compose_block/2 clause that reads it:
  #   action   → PdButton {href, label, priority?}; empty href/label defaults.
  #   figure   → figure_html(child, caption); a caption-less figure wrapping ONE child.
  #   columns  → a list of columns, each a list of blocks; two empty columns.
  #   terminal → chrome frame over `children`; empty body (the reader renders bare chrome).
  #   table    → PdTable {rows, head?}; a headed 1-body 2-col grid with empty cells.
  def default_block("action", id),
    do: %{"id" => id, "type" => "action", "href" => "", "label" => ""}

  def default_block("figure", id),
    do: %{
      "id" => id,
      "type" => "figure",
      "child" => %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}
    }

  def default_block("columns", id),
    do: %{"id" => id, "type" => "columns", "columns" => [[], []]}

  def default_block("terminal", id),
    do: %{"id" => id, "type" => "terminal", "children" => []}

  def default_block("table", id),
    do: %{"id" => id, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}

  # ── leaf field-* blocks (P2.1) — Basic fields group ──
  # string / slug / text share the {label, value:""} shape; the field-text
  # editor also reads an optional "rows" but defaults to 3 when absent.
  def default_block("field-string", id),
    do: %{"id" => id, "type" => "field-string", "label" => "Text", "value" => ""}

  def default_block("field-slug", id),
    do: %{"id" => id, "type" => "field-slug", "label" => "Slug", "value" => ""}

  def default_block("field-text", id),
    do: %{"id" => id, "type" => "field-text", "label" => "Long text", "value" => ""}

  def default_block("field-boolean", id),
    do: %{"id" => id, "type" => "field-boolean", "label" => "Boolean", "value" => false}

  def default_block("field-datetime", id),
    do: %{"id" => id, "type" => "field-datetime", "label" => "Date & time", "value" => ""}

  def default_block("field-color", id),
    do: %{"id" => id, "type" => "field-color", "label" => "Color", "value" => "#000000"}

  def default_block("field-number", id),
    do: %{"id" => id, "type" => "field-number", "label" => "Number", "value" => nil}

  def default_block("field-select", id),
    do: %{
      "id" => id,
      "type" => "field-select",
      "label" => "Select",
      "value" => "",
      "options" => [
        %{"value" => "option-1", "label" => "Option 1"},
        %{"value" => "option-2", "label" => "Option 2"}
      ]
    }

  # ── picker field-* blocks (P2.2) — Media & reference group ──
  # field-reference's refType is empty by default; the picker still browses all
  # types when ref-type is "". field-image's value is an empty image URL.
  def default_block("field-reference", id),
    do: %{
      "id" => id,
      "type" => "field-reference",
      "label" => "Reference",
      "refType" => "",
      "value" => ""
    }

  def default_block("field-image", id),
    do: %{"id" => id, "type" => "field-image", "label" => "Image", "value" => ""}

  # ── v2 composite field-* blocks (P2.3) — Structured group ──
  # composite carries an inline "fields" config (subfields use name/type/title,
  # matching PaperFieldBlock.build_subfield/1 + Render.compose_block/1) and a
  # structured map "value". arrayOf carries an "of" element descriptor + an
  # "ordered" flag + a list "value". codelist carries a (here empty) codelistId
  # + a scalar "value". localizedText carries a language set + a "format" + a
  # %{lang => text} "value".
  def default_block("composite", id),
    do: %{
      "id" => id,
      "type" => "composite",
      "label" => "Composite",
      "fields" => [%{"name" => "field1", "type" => "string", "title" => "Field 1"}],
      "value" => %{}
    }

  def default_block("arrayOf", id),
    do: %{
      "id" => id,
      "type" => "arrayOf",
      "label" => "Array",
      "of" => %{"type" => "string"},
      "ordered" => false,
      "value" => []
    }

  # codelist defaults to a REAL registered list so the picker is usable the
  # moment a block is added. `plugin` is the registry discriminator (defaults
  # to "core" in CodelistField; OnixEdit codelists live under "onixedit").
  # `variant` selects the picker UI: "flat" (default) renders CodelistField's
  # <select>/<datalist>; "tree" forces the hierarchical TreeCodelistField (see
  # PaperFieldBlock). onixedit:list_15 ("Title type", 16 flat entries) is a
  # small flat list — a clean default for the <select> path. Publishers may
  # override `codelistId`/`plugin`/`version`/`variant` per their Expectations.
  def default_block("codelist", id),
    do: %{
      "id" => id,
      "type" => "codelist",
      "label" => "Code list",
      "plugin" => "onixedit",
      "codelistId" => "onixedit:list_15",
      "version" => 73,
      "variant" => "flat",
      "value" => ""
    }

  def default_block("localizedText", id),
    do: %{
      "id" => id,
      "type" => "localizedText",
      "label" => "Localized text",
      "languages" => ["en"],
      "format" => "plain",
      "value" => %{}
    }

  def default_block(_unknown, id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}
end
