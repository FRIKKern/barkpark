defmodule Barkpark.Preview do
  @moduledoc """
  The document **preview manifest** — one OpenGraph-shaped card per document,
  computed at WRITE TIME beside `content["body"]` so it can never drift, and
  consumed by every surface (share heads, internal cards, boards).

  Modelled on the Open Graph protocol (ogp.me): a document projects to ONE
  string-keyed manifest —

      %{
        "title"       => "My Paper",
        "type"        => "paper",           # RAW doctype; emitters map to og:type
        "description" => "First 110 chars…",
        "url"         => "/papers/my-paper",# RELATIVE; emitters absolutize (D3)
        "image"       => %{"url" => "/media/renditions/…/og",
                           "width" => 1200, "height" => 630,
                           "alt" => "…", "type" => "image/jpeg"} | nil,
        "extensions"  => %{…}               # sparse, per-doctype (D9)
      }

  ## Purity by injection (D2)

  `project/3` is PURE — no Repo, no mutation. The ONE read-only lookup a rich
  card needs (a media file's `og` rendition url) is injected as a closure via
  `opts.media_resolver`. Callers that hold Repo + tenancy scope build that
  closure with `media_resolver/1` and pass it in. With NO `:media_resolver`
  (and no other opts) `project/3` still returns a valid, degraded manifest —
  the degradation invariant. This mirrors how `Projection.project/4` stays
  Repo-free while `content["body"]` is derived on every write.

  NOT to be confused with `/v1/preview` (the draft-preview token tunnel,
  `Barkpark.Papers.PreviewToken`) — that is a different capability entirely.

  ## Fallback chains

    * **image** — first `role: "featured"` free image block with a non-empty
      `src`, else the first free image block with a non-empty `src`, else `nil`
      (emitters then show the branded default card).
    * **title** — `content["title"]` → the `role: "title"` block's text → an
      injected row title (`opts.title`) → `nil`.
    * **description** — an explicit excerpt field (`excerpt`/`description`/
      `summary`) → the first free ingress-or-paragraph block's plain text (A6)
      → `nil`; truncated to ~110 chars on a word boundary with an ellipsis (D11).
    * **image alt** — the featured block's `alt` → the document title.

  A media `src` (`/media/files/<path>`) resolves through the injected resolver
  to the constant-geometry `og` rendition (1200×630); an external `http(s)`
  `src` passes through raw with the block's own dimensions.
  """

  alias Barkpark.Media
  alias Barkpark.Media.Renditions

  @title_role "title"
  @featured_role "featured"

  # ogp.me recommends ~2 sentences; we cap at ~110 chars, cut on a word boundary.
  @description_max 110

  # The `og` rendition is a fixed 1200×630 exact crop (Renditions preset + D4),
  # so a MediaFile-backed image can hardcode these with no per-asset lookup.
  @og_width 1200
  @og_height 630

  @typedoc "The string-keyed preview manifest."
  @type manifest :: %{required(String.t()) => term()}

  @typedoc "A resolved image object (or nil when there is no usable image)."
  @type image :: %{required(String.t()) => term()} | nil

  @doc """
  Project a document's `content` + full `blocks` list into the preview manifest.

  `opts` (all optional):

    * `:media_resolver` — `(src :: String.t() -> map() | nil)` closure mapping a
      `/media/files/<path>` src to `%{"url","width","height","type"}` (see
      `media_resolver/1`). Absent ⇒ media-backed images degrade to `nil`.
    * `:doc_type` — the raw doctype string (`"paper"`, `"task"`, …). Absent ⇒
      `content["type"]` ⇒ `"document"`.
    * `:url` — the document's RELATIVE reader url (e.g. `/papers/<slug>`).
    * `:title` — the document row title, used as the last title fallback.

  PURE: no Repo, no mutation of inputs.
  """
  # @canonical capability:preview-manifest aka:og,opengraph,unfurl,share-card,twitter-card
  @spec project(map(), [map()], map()) :: manifest()
  def project(content, blocks, opts \\ %{})
      when is_map(content) and is_list(blocks) and is_map(opts) do
    doc_type = doc_type(content, opts)
    title = title(content, blocks, opts)

    %{
      "title" => title,
      "type" => doc_type,
      "description" => description(content, blocks),
      "url" => blank_to_nil(Map.get(opts, :url)),
      "image" => image(blocks, opts, title),
      "extensions" => extensions(doc_type, content)
    }
  end

  @doc """
  Build the media-resolver closure `project/3` injects for a rich image.

  Maps a `/media/files/<path>` block `src` to the file's `og` rendition —
  `%{"url" => <relative>, "width" => 1200, "height" => 630, "type" =>
  "image/jpeg"}` — or `nil` when the path resolves to no media file (or the file
  has no `og` rendition url). `scope` may carry tenancy (`:workspace_id` /
  `:project_id`); it is forwarded to `Media.get_file_by_path/2` so a scoped
  write never resolves another tenant's blob.

  The closure is the ONLY Repo-touching part of this module and it runs only
  when a caller injects it — `project/3` itself stays pure.
  """
  @spec media_resolver(keyword()) :: (String.t() -> map() | nil)
  def media_resolver(scope \\ []) when is_list(scope) do
    fn src ->
      with path when is_binary(path) <- media_rel_path(src),
           {:ok, file} <- Media.get_file_by_path(path, scope),
           url when is_binary(url) <- Renditions.url(file, "og") do
        %{
          "url" => url,
          "width" => @og_width,
          "height" => @og_height,
          "type" => "image/jpeg"
        }
      else
        _ -> nil
      end
    end
  end

  # ── type ───────────────────────────────────────────────────────────────────

  defp doc_type(content, opts) do
    (blank_to_nil(Map.get(opts, :doc_type)) ||
       blank_to_nil(Map.get(content, "type")) ||
       "document")
    |> to_string()
  end

  # ── title ──────────────────────────────────────────────────────────────────

  defp title(content, blocks, opts) do
    blank_to_nil(Map.get(content, "title")) ||
      title_block_text(blocks) ||
      blank_to_nil(Map.get(opts, :title))
  end

  defp title_block_text(blocks) do
    Enum.find_value(blocks, fn
      %{"role" => @title_role, "text" => text} -> blank_to_nil(text)
      _ -> nil
    end)
  end

  # ── description ─────────────────────────────────────────────────────────────

  defp description(content, blocks) do
    case explicit_excerpt(content) || first_paragraph_text(blocks) do
      nil -> nil
      text -> truncate(text, @description_max)
    end
  end

  defp explicit_excerpt(content) do
    blank_to_nil(Map.get(content, "excerpt")) ||
      blank_to_nil(Map.get(content, "description")) ||
      blank_to_nil(Map.get(content, "summary"))
  end

  # "First body paragraph" = the first free block of type ingress OR paragraph
  # in document order (A6): live papers commonly open eyebrow → heading →
  # ingress, and the ingress IS the lead prose.
  defp first_paragraph_text(blocks) do
    Enum.find_value(blocks, fn block ->
      if free?(block) and match?(%{"type" => t} when t in ["ingress", "paragraph"], block) do
        blank_to_nil(paragraph_text(block))
      end
    end)
  end

  defp paragraph_text(%{"content" => nodes}) when is_list(nodes),
    do: nodes |> Enum.map_join("", &node_text/1) |> String.trim()

  defp paragraph_text(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp paragraph_text(_), do: ""

  defp node_text(%{"content" => nodes}) when is_list(nodes),
    do: Enum.map_join(nodes, "", &node_text/1)

  # The canonical stored inline-mark shape (inline.ex `compose_inline`) wraps a
  # span's text under "children", NOT "content" — strong/em/code/strike/link/
  # wikilink all do. Without this clause every marked span vanishes, producing
  # the live 'Barkpahis paper… writes , a compiler' garble (D15). No corpus node
  # carries both "children" and "value", so this clause precedes the value clause
  # safely; nested marks recurse.
  defp node_text(%{"children" => nodes}) when is_list(nodes),
    do: Enum.map_join(nodes, "", &node_text/1)

  defp node_text(%{"value" => v}) when is_binary(v), do: v
  defp node_text(%{"text" => t}) when is_binary(t), do: t
  defp node_text(_), do: ""

  # First `@description_max` chars, cut back to the last whole word (unless the
  # first word alone already overflows), + an ellipsis.
  defp truncate(text, max) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      head = String.slice(text, 0, max)

      trimmed =
        case Regex.replace(~r/\s+\S*$/u, head, "") do
          "" -> head
          shorter -> shorter
        end

      String.trim_trailing(trimmed) <> "…"
    end
  end

  # ── image ──────────────────────────────────────────────────────────────────

  defp image(blocks, opts, title) do
    resolver = Map.get(opts, :media_resolver)

    blocks
    |> image_candidates()
    |> Enum.find_value(fn block -> resolve_image(block, resolver, title) end)
  end

  # Featured free image blocks first, then the remaining free image blocks, all
  # with a non-blank src — the D-ordered fallback chain.
  defp image_candidates(blocks) do
    images = Enum.filter(blocks, &image_block?/1)
    {featured, rest} = Enum.split_with(images, &featured?/1)
    featured ++ rest
  end

  defp image_block?(block),
    do: free?(block) and match?(%{"type" => "image"}, block) and non_blank_src?(block)

  defp featured?(%{"role" => @featured_role}), do: true
  defp featured?(_), do: false

  defp non_blank_src?(%{"src" => src}) when is_binary(src), do: String.trim(src) != ""
  defp non_blank_src?(_), do: false

  defp resolve_image(block, resolver, title) do
    src = block |> Map.get("src") |> to_string() |> String.trim()
    alt = blank_to_nil(Map.get(block, "alt")) || title

    cond do
      # A media asset: resolve to its constant-geometry `og` rendition. With no
      # resolver injected (degraded), a media image can't be sized → nil.
      media_rel_path(src) ->
        if is_function(resolver, 1) do
          case resolver.(src) do
            %{} = resolved -> Map.put(resolved, "alt", alt)
            _ -> nil
          end
        end

      # External + any other relative src: pass through raw with block dims.
      src != "" ->
        %{
          "url" => src,
          "width" => positive_int(Map.get(block, "width")),
          "height" => positive_int(Map.get(block, "height")),
          "alt" => alt,
          "type" => nil
        }

      true ->
        nil
    end
  end

  # ── extensions (D9 — sparse, per-doctype) ───────────────────────────────────

  defp extensions("paper", content) do
    compact(%{
      "published_time" =>
        first_string(content, ["published_time", "publishedAt", "published_at"]),
      "authors" => string_list(content, ["authors", "author"]),
      "tags" => paper_tags(content),
      "section" => first_string(content, ["section"])
    })
  end

  defp extensions("task", content) do
    compact(%{
      "status" => first_string(content, ["lifecycle_status", "status"]),
      "assignee" => first_string(content, ["assignee"]),
      "done_ratio" => number(content, ["done_ratio"]),
      "priority" => number(content, ["priority"])
    })
  end

  defp extensions("sheet", content) do
    compact(%{"tab_count" => tab_count(content)})
  end

  # Real ticket docs store the sender key under `key_name` and the turn indicator
  # under `status` (tickets.ex:137/154) — the shipped `key`/`state` reads never
  # matched, so this ext was always empty (D16). Read the real fields; the
  # manifest output keys stay `key`/`state` per D9.
  defp extensions("ticket", content) do
    compact(%{
      "key" => first_string(content, ["key_name"]),
      "state" => first_string(content, ["status"])
    })
  end

  defp extensions(_type, _content), do: %{}

  defp tab_count(content) do
    Enum.find_value(["tabs", "sheets"], fn key ->
      case Map.get(content, key) do
        list when is_list(list) -> length(list)
        _ -> nil
      end
    end)
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp media_rel_path("/media/files/" <> path) when path != "", do: path
  defp media_rel_path(_), do: nil

  # A block is FREE unless it carries a non-blank string fieldName (the same
  # partition rule as PortableDoc.Projection.bound?/1).
  defp free?(%{"fieldName" => name}) when is_binary(name) and name != "", do: false
  defp free?(_), do: true

  defp first_string(content, keys), do: Enum.find_value(keys, &blank_to_nil(Map.get(content, &1)))

  defp paper_tags(content) do
    case Map.get(content, "tags") do
      [_ | _] = tags ->
        tags
        |> Enum.map(fn
          %{"tag" => tag} when is_binary(tag) -> tag
          tag when is_binary(tag) -> tag
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> presence()

      tag when is_binary(tag) ->
        tag |> blank_to_nil() |> List.wrap() |> presence()

      _ ->
        nil
    end
  end

  defp string_list(content, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(content, key) do
        [_ | _] = list -> list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> presence()
        s when is_binary(s) -> s |> blank_to_nil() |> List.wrap() |> presence()
        _ -> nil
      end
    end)
  end

  defp number(content, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(content, key) do
        n when is_number(n) -> n
        _ -> nil
      end
    end)
  end

  defp presence([]), do: nil
  defp presence(list) when is_list(list), do: list

  # Drop nil / empty-string / empty-list values so extensions stay sparse.
  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      _ -> s
    end
  end

  defp blank_to_nil(_), do: nil
end
