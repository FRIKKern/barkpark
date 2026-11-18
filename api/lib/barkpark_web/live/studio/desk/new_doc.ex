defmodule BarkparkWeb.Studio.Desk.NewDoc do
  @moduledoc """
  A new document on the desk (J18), the TanStack Studio's way
  (`app/src/lib/templates.ts`, `startNew`): it exists only in the page until
  its first edit. Leaving it costs nothing, and no row is written for it.

  Create new picks a way to start the type (`choices/1`): the type itself,
  with its `initial_values`, or one of the templates its desk block names
  (`desk.templates`, each `%{"id", "title", "value"}`). The page mints a uuid
  and opens `<list>;<uuid>,template=<choice id>` (`Desk.Panes` prints it), as
  the TanStack Studio does. The URL says it is a new document, so a reload
  before the first edit opens the same new document again.

  `prepare/1` reads the last pane when the editor is loaded: a template
  pane with a uuid that names no stored row is `desk_new`. The Studio's own
  pane walk finds no document for it, so `editor/2` hands it one that is not
  stored: the initial values and the template's values, no rev. The first
  write the editor makes (`Shared.do_autosave/3`, the one save path, with its
  authorization) inserts the row; from then on the stored document is the
  editor's. A post that changes nothing is not written (`guard/3`), and the
  birth is held to the document quota, as Create new is.

  Some types are built at once, as before (`deferred?/1` is false): a type
  born with content of its own (a paper, a sheet, a task, a session) or with
  a layout to build from. Barkpark builds those on Create new.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Forms
  alias Barkpark.Content.Writer
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.QuotaGate
  alias BarkparkWeb.Studio.StudioLive.Shared

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # The Studio's events that write the open document from its form.
  @form_writes ~w(save autosave)

  # The document's actions: none acts on a document not stored yet.
  @actions ~w(publish unpublish discard-draft duplicate-doc delete-doc confirm-delete
              schema_action restore-revision)

  @type choice :: %{id: String.t(), title: String.t(), type: String.t(), value: map()}

  @doc """
  The ways to start `schema`'s type: its own first, then its desk block's
  templates in their order. A template with parameters waits for a list that
  passes them, so it is not offered here.
  """
  @spec choices(map()) :: [choice()]
  def choices(%{name: type} = schema) do
    own = %{id: type, title: schema.title || type, type: type, value: %{}}
    [own | templates(schema)]
  end

  defp templates(%{name: type} = schema) do
    for %{"id" => id, "title" => title} = t <- List.wrap((schema.desk || %{})["templates"]),
        is_binary(id) and id != "" and id != type and is_binary(title) and title != "",
        is_map(t["value"] || %{}) and t["parameters"] in [nil, []],
        do: %{id: id, title: title, type: type, value: t["value"] || %{}}
  end

  @doc "The choice `id` names for `schema`'s type, or nil."
  @spec choice(map(), term()) :: choice() | nil
  def choice(schema, id), do: Enum.find(choices(schema), &(&1.id == id))

  @doc """
  Whether a new document of this type waits for its first edit. One born
  with content of its own, or with a layout to build, is made at once.
  """
  @spec deferred?(map()) :: boolean()
  def deferred?(%{name: type} = schema) do
    type not in ~w(task sheet graph mediaAsset) and not Content.blocks_type?(type) and
      Shared.seed_new_doc_content(type) == %{} and (schema.layout || []) == []
  end

  @doc "A fresh id for a new document, the TanStack Studio's `crypto.randomUUID()`."
  @spec mint() :: String.t()
  def mint, do: Ecto.UUID.generate()

  @doc """
  A press of Create new (`new-document`, its `template`): the new document to
  open, `%{kind: :doc, id, type, template}`, when its type waits for its first
  edit; nil when the Studio makes it (a type built at once) or refuses it (no
  such type, or one its authors do not create).
  """
  def start(type, params, socket) do
    with {:ok, schema} <-
           Content.resolve_schema(type, socket.assigns.dataset, Shared.hook_opts(socket)),
         true <- PaneBuilder.author_creatable?(schema) and deferred?(schema) do
      %{id: template} = choice(schema, params["template"]) || choice(schema, type)
      %{kind: :doc, id: mint(), type: type, template: template}
    else
      _ -> nil
    end
  end

  @doc "Whether `id` has the shape `mint/0` gives."
  def uuid?(id), do: is_binary(id) and Regex.match?(@uuid, id)

  @doc """
  The new document the last pane names, as `desk_new`: a pane with a
  `template`, a uuid, a type that can be created here and waits for its first
  edit, and no stored row. Anything else is no new document.
  """
  def prepare(socket) do
    assign(socket, :desk_new, unborn(List.last(socket.assigns[:chain] || []), socket))
  end

  defp unborn(%{kind: :doc, id: id, type: type, template: template}, socket) do
    %{dataset: dataset} = socket.assigns
    opts = Shared.hook_opts(socket)

    with true <- uuid?(id),
         {:ok, schema} <- Content.resolve_schema(type, dataset, opts),
         true <- PaneBuilder.author_creatable?(schema) and deferred?(schema),
         %{} = choice <- choice(schema, template),
         {nil, _draft?, _published?} <- Content.fetch_doc_with_draft(type, id, dataset, opts) do
      %{id: id, type: type, content: content(schema, choice)}
    else
      _ -> nil
    end
  end

  defp unborn(_pane, _socket), do: nil

  # What the form shows before the first edit, and what the first write
  # starts from: the type's initial values, then the template's, each in the
  # stored shape (a reference by id is stored as `{_ref, _type}`).
  defp content(schema, choice) do
    initial = Writer.resolve_dynamics(schema.initial_values || %{})
    Writer.deep_merge(initial, Forms.coerce_params(choice.value, schema))
  end

  @doc """
  The Studio's editor for its pane walk (`Shared.rebuild_panes/1`): when the
  walk found no document and the path names the new one, the new one, not
  stored yet.
  """
  def editor(nil, %{assigns: %{desk_new: %{id: id, type: type} = new}} = socket) do
    with ^id <- List.last(socket.assigns[:nav_path] || []),
         {:ok, schema} <-
           Content.resolve_schema(type, socket.assigns.dataset, Shared.hook_opts(socket)) do
      doc = %Document{doc_id: "drafts." <> id, type: type, content: new.content, rev: nil}

      %{
        doc: doc,
        schema: schema,
        type: type,
        is_draft: true,
        has_published: false,
        form: Content.doc_to_form(doc, schema)
      }
    else
      _ -> nil
    end
  end

  def editor(editor, _socket), do: editor

  @doc "Whether the editor holds the new document, not stored yet."
  def unborn?(%{desk_new: %{id: id}, editor_doc: %Document{doc_id: doc_id, rev: nil}}),
    do: Content.published_id(doc_id) == id

  def unborn?(_assigns), do: false

  @doc """
  Before an event the editor answers: `:cont` to let it through, or
  `{:halt, socket}`. Only for the new document, before it is stored: a form
  post that changes nothing is not written (it would store a document no one
  edited), and a write that would store it needs room for one more document.
  """
  def guard(event, params, socket) do
    cond do
      not unborn?(socket.assigns) ->
        :cont

      event in @actions ->
        {:halt, socket}

      event in @form_writes and not edits?(params, socket.assigns) ->
        {:halt, socket}

      BarkparkWeb.Studio.Caps.classify(event) != :write ->
        :cont

      true ->
        room(socket)
    end
  end

  @doc """
  Before a write the page builds itself (Paste field): the new document's
  first write stores it, so it needs room for one more document.
  """
  def room(socket) do
    with true <- unborn?(socket.assigns),
         {:error, message} <- QuotaGate.check(workspace_id(socket.assigns), 1) do
      {:halt, put_flash(socket, :error, message)}
    else
      _ -> :cont
    end
  end

  @doc "The document's menu items: none of its actions before it is stored."
  def offered(items, assigns) do
    if unborn?(assigns), do: Enum.reject(items, &(&1[:event] in @actions)), else: items
  end

  defp workspace_id(%{current_workspace: %{id: id}}), do: id
  defp workspace_id(_assigns), do: nil

  # The writer's own reading of a post (`Forms.edited_keys/4`), on what the
  # form drew for the new document. An empty title is no title.
  defp edits?(%{"doc" => %{} = posted}, assigns) do
    %{editor_doc: doc, editor_type: type, editor_schema: schema} = assigns

    posted =
      posted
      |> Map.reject(fn {key, value} ->
        String.starts_with?(key, "_unused_") or (key == "title" and value in ["", nil])
      end)
      |> Forms.coerce_params(schema)

    posted != %{} and Forms.edited_keys(doc, type, schema, posted) != []
  end

  defp edits?(_params, _assigns), do: false

  @doc "Once the first write stored it, the new document is the stored one."
  def settle(
        %{assigns: %{desk_new: %{id: id}, editor_doc: %Document{doc_id: doc_id, rev: rev}}} =
          socket
      )
      when is_binary(rev) do
    if Content.published_id(doc_id) == id, do: assign(socket, :desk_new, nil), else: socket
  end

  def settle(socket), do: socket
end
