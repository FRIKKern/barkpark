defmodule Barkpark.Content.LinkHrefFence do
  @moduledoc """
  A write that brings a link address `Content.LinkHref` refuses into
  Portable Text is refused (task-b923a915151d2038).

  #28371 draws a stored `javascript:`, `data:` or `vbscript:` link as its
  words and keeps the editors from making one, as TanStack does
  (`app/src/lib/link-href.ts`: `linkHref` refuses it at link creation,
  `storedHref` draws a stored one as words). A JSON write (the mutate door,
  an import, another client) could still store one, and every reader of the
  stored JSON other than ours would get it.

  ## The level: every write, new addresses only, every dataset

  TanStack refuses the address where it is made, not at publish, and so
  does the Classic editor's save (`PortableText.from_html` never links one).
  Refusing only at publish would leave it in a draft, which preview clients
  read. So the check runs on every create and update, on every dataset: it
  is a security rule, not a schema rule, and does not wait for
  `Validation.enforce?/1`.

  A row stored before this check (or an import that wrote one) must stay
  editable, so only a NEW address is refused: one that neither the row being
  written nor its draft or published twin already holds. Editing the words
  around a stored one, or another field, writes.

  ## What is read

  A mark definition in any `markDefs` list in the content (a Portable Text
  block anywhere: a top-level field, an object, an array row): a `link`'s
  `href`, and a `linkAnnotation`'s `url`, `href` and `damFileUrl`. An empty
  address is not a link.

  The refusal is the mutate door's `validation_failed` (422), with one
  finding per address under the code `pt_link_href_refused`. Nothing is
  written.
  """

  alias Barkpark.Content
  alias Barkpark.Content.LinkHref

  @code :pt_link_href_refused

  @link_keys %{"link" => ~w(href), "linkAnnotation" => ~w(url href damFileUrl)}

  @doc "The finding code this fence refuses with."
  @spec code() :: atom()
  def code, do: @code

  @doc """
  A pre-write fence (`Content.PreWriteFences.run/2`'s argument list): `:ok`,
  or `{:error, {:schema_validation_failed, errors, findings}}` naming each
  new refused address.
  """
  def refuse_new(type, attrs, dataset, doc_id, prev_doc, opts) do
    case refused(content(attrs), "") do
      [] ->
        :ok

      found ->
        found
        |> drop_held(held(prev_doc))
        |> drop_twin_held(type, dataset, doc_id, opts)
        |> refusal()
    end
  end

  @doc """
  Each refused address in `content` as `{path, address}`, the path a JSON
  pointer from the content's root.
  """
  @spec refused(term(), String.t()) :: [{String.t(), String.t()}]
  def refused(%{} = map, path) when not is_struct(map) do
    defs =
      case Map.get(map, "markDefs") do
        list when is_list(list) -> def_findings(list, path <> "/markDefs")
        _ -> []
      end

    defs ++ Enum.flat_map(map, fn {k, v} -> refused(v, "#{path}/#{escape(k)}") end)
  end

  def refused(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> refused(v, "#{path}/#{i}") end)
  end

  def refused(_value, _path), do: []

  defp def_findings(defs, path) do
    for {%{"_type" => type} = def, i} <- Enum.with_index(defs),
        key <- Map.get(@link_keys, type, []),
        href = def[key],
        is_binary(href) and href != "",
        not LinkHref.allowed?(href),
        do: {"#{path}/#{i}/#{key}", href}
  end

  defp content(attrs) when is_map(attrs),
    do: Map.get(attrs, "content") || Map.get(attrs, :content)

  defp content(_attrs), do: nil

  defp held(%{content: content}), do: MapSet.new(refused(content, ""), &elem(&1, 1))
  defp held(_doc), do: MapSet.new()

  defp drop_held(found, held), do: Enum.reject(found, fn {_path, href} -> href in held end)

  # Read only when an address is still new: the draft's first write carries
  # what the published row holds, and a publish what the draft held.
  defp drop_twin_held([], _type, _dataset, _doc_id, _opts), do: []

  defp drop_twin_held(found, type, dataset, doc_id, opts) when is_binary(doc_id) do
    twin =
      case doc_id do
        "drafts." <> published -> published
        draft -> "drafts." <> draft
      end

    case Content.get_document(twin, type, dataset, opts) do
      {:ok, doc} -> drop_held(found, held(doc))
      _ -> found
    end
  end

  defp drop_twin_held(found, _type, _dataset, _doc_id, _opts), do: found

  defp refusal([]), do: :ok

  defp refusal(found) do
    findings =
      for {path, _href} <- found do
        %{
          path: path,
          message:
            "link address not allowed: a link may carry http, https, mailto, tel, " <>
              "a relative or an in-document address",
          code: @code,
          params: %{key: path |> String.split("/") |> List.last()}
        }
      end

    errors =
      findings
      |> Enum.group_by(&top_level/1, &"#{&1.path}: #{&1.message}")

    {:error, {:schema_validation_failed, errors, findings}}
  end

  defp top_level(%{path: "/" <> rest}), do: rest |> String.split("/") |> hd()

  defp escape(key) when is_binary(key),
    do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp escape(key), do: to_string(key)
end
