defmodule BarkparkWeb.Studio.Desk.SlugInUse do
  @moduledoc """
  Sanity's slug rule in the desk's editor, the TanStack Studio's way
  (`lib/slug-unique.ts` `useSlugInUse`, `slugsTakenNow`): a slug another
  document of the same type already has is an error, "Slug is already in
  use". So a duplicate shows its copied slug as taken.

  The answers are kept in `desk_slugs`, one per document, field and value,
  each for 10 seconds, as TanStack keeps its query's (`staleTime`). After a
  change the editor answers (`refresh/1`, from `EditorHost`), a slug field
  whose value has no fresh answer is asked once (`Content.SlugInUse`: one
  indexed query, under the socket's read scope, yes or no). A value the
  author has not changed is not asked again until its answer is stale.

  A taken slug is one of the pane's problems (`problems/1`, which
  `ValidationPanel.problems/1` lists): the Validation button and panel name
  it, Publish is blocked, and the field's label carries the mark
  (`mark/1`, through `Desk.FieldSlots`). Publish asks again first
  (`guard/2`), since someone may have taken the slug since the last answer;
  a slug taken meanwhile refuses it.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Barkpark.Content
  alias Barkpark.Content.SlugInUse, as: Rule
  alias BarkparkWeb.Studio.StudioLive.Shared

  @fresh_ms 10_000

  @doc "The answers kept, read again after each change the editor answers."
  def refresh(socket) do
    case asks(socket.assigns) do
      [] -> socket
      asks -> keep(socket, asks, fn {_key, at} -> fresh?(at) end)
    end
  end

  @doc """
  Before an event the editor answers: Publish asks every slug again, and a
  slug taken now refuses it (`{:halt, socket}`). Anything else is `:cont`.
  """
  def guard("publish", socket) do
    asks = asks(socket.assigns)
    socket = keep(socket, asks, fn _ -> false end)

    case taken_titles(socket.assigns, asks) do
      [] -> :cont
      titles -> {:halt, put_flash(socket, :error, "#{Enum.join(titles, ", ")}: #{words()}")}
    end
  end

  def guard(_event, _socket), do: :cont

  @doc "The open document's slug fields that are taken, as `ValidationPanel` problems."
  def problems(assigns) do
    for {field, value} <- slugs(assigns), taken?(assigns, field, value) do
      %{
        path: field["name"],
        title: field["title"] || field["name"],
        parents: [],
        message: words(),
        level: "error",
        group: group(field),
        item: nil,
        slug_in_use: true
      }
    end
  end

  @doc "The taken-slug problem of the field named `name`, or nil."
  def problem(assigns, name) when is_binary(name) do
    Enum.find(problems(assigns), &(&1.path == name))
  end

  def problem(_assigns, _name), do: nil

  attr :problem, :map, default: nil

  @doc """
  The mark beside a field's label, as TanStack's `ProblemMark`: Sanity's
  error icon, named by its level and message.
  """
  def mark(assigns) do
    ~H"""
    <span
      :if={@problem}
      class="error-icon"
      data-level="error"
      data-desk-slug-in-use
      role="img"
      aria-label={gettext("Validation error: %{message}", message: @problem.message)}
      title={@problem.message}
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="21" height="21" viewBox="0 0 25 25" fill="none" aria-hidden="true">
        <path
          d="M12.5 16V14.5M12.5 9V13M20.5 12.5C20.5 16.9183 16.9183 20.5 12.5 20.5C8.08172 20.5 4.5 16.9183 4.5 12.5C4.5 8.08172 8.08172 4.5 12.5 4.5C16.9183 4.5 20.5 8.08172 20.5 12.5Z"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linejoin="round"
        />
      </svg>
    </span>
    """
  end

  @doc "The mark's look: TanStack's `.error-icon` in a label."
  def css do
    """
    .dk label > .error-icon[data-desk-slug-in-use], .dk legend > .error-icon[data-desk-slug-in-use] { display: inline-grid; place-items: center; margin: -1px 0 -1px 6px; vertical-align: middle; color: var(--dk-critical-icon); }
    .dk label > .error-icon[data-desk-slug-in-use] svg, .dk legend > .error-icon[data-desk-slug-in-use] svg { width: 21px; height: 21px; }
    """
  end

  defp words, do: gettext("Slug is already in use")

  # The asks for the open document: {key, field, value} per slug field with a value.
  defp asks(assigns) do
    case doc_key(assigns) do
      nil ->
        []

      {_type, id} = doc ->
        for {field, value} <- slugs(assigns), do: {{doc, field["name"], value}, id}
    end
  end

  defp keep(socket, asks, fresh?) do
    %{assigns: %{editor_type: type, dataset: dataset} = assigns} = socket
    kept = Map.get(assigns, :desk_slugs) || %{}
    opts = Shared.hook_opts(socket)

    answers =
      for {{_doc, name, value} = key, id} <- asks, into: %{} do
        case Map.get(kept, key) do
          {_taken?, at} = answer when is_integer(at) ->
            if fresh?.({key, at}),
              do: {key, answer},
              else: {key, ask(type, name, value, id, dataset, opts)}

          _ ->
            {key, ask(type, name, value, id, dataset, opts)}
        end
      end

    # Only the open document's answers are kept: another one's go with it.
    Phoenix.Component.assign(socket, :desk_slugs, answers)
  end

  defp ask(type, name, value, id, dataset, opts),
    do: {Rule.taken?(type, name, value, id, dataset, opts), now()}

  defp taken_titles(assigns, asks) do
    for {{_doc, name, _value} = key, _id} <- asks,
        match?({true, _}, Map.get(assigns.desk_slugs, key)),
        field = Enum.find(fields(assigns), &(&1["name"] == name)),
        do: field["title"] || name
  end

  defp taken?(assigns, field, value) do
    case doc_key(assigns) do
      nil -> false
      doc -> match?({true, _}, Map.get(assigns[:desk_slugs] || %{}, {doc, field["name"], value}))
    end
  end

  # The open document's slug fields that hold a value, with its text.
  defp slugs(assigns) do
    content = (assigns[:editor_doc] && assigns.editor_doc.content) || %{}

    for field <- fields(assigns),
        value = Rule.text(Map.get(content, field["name"])),
        value != nil,
        do: {field, value}
  end

  defp fields(%{editor_schema: %{fields: fields}}) when is_list(fields),
    do: Enum.filter(fields, &(is_map(&1) and &1["type"] == "slug" and is_binary(&1["name"])))

  defp fields(_assigns), do: []

  defp doc_key(%{editor_type: type, editor_doc: %{doc_id: doc_id}})
       when is_binary(type) and is_binary(doc_id),
       do: {type, Content.published_id(doc_id)}

  defp doc_key(_assigns), do: nil

  defp group(%{"group" => group}) when is_binary(group) and group != "", do: group
  defp group(%{"group" => [group | _]}) when is_binary(group), do: group
  defp group(_field), do: nil

  defp fresh?(at), do: now() - at < @fresh_ms
  defp now, do: System.monotonic_time(:millisecond)
end
