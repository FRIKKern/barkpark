defmodule BarkparkWeb.Studio.Desk.PublishedView do
  @moduledoc """
  The published perspective of the desk's edit pane (`?perspective=published`,
  `Panes.perspective/1`), as the TanStack Studio draws it (`DocumentPane.tsx`:
  `viewingPublished`, `PublishedFooter`): the published version, read-only.

  - The form is the Studio's own, drawn over the published version in a
    disabled fieldset, every field locked as an old revision's is
    (`RevisionView.locked/1`): nothing in it can be typed in or pressed, and
    no rich text, reference or block canvas is mounted for it. The editor
    keeps the draft as it is.
  - A document with no published version (never published, or unpublished)
    keeps the form, empty and read-only, as Sanity's does (J04).
  - The page takes only the events that cannot write the open document, and
    Unpublish (`refuses?/2`): a form post, a field's press, a document action
    or a plugin's event sent by hand is dropped (`EditorHost`). The header
    menu keeps only what opens or links, and Copy document (`menu/2`).
  - The footer says "Last published 2h ago", or "Unpublished just now" when
    there is no published version and the last publish-or-unpublish in the
    history was an unpublish; Unpublish sits in Publish's place
    (`DocFooter.bar/1`).
  - An old revision (`rev`) the URL names is drawn in this view's place, as
    TanStack's (`RevisionView`).
  - A sheet's grid and a paper's canvas are their own editors
    (LiveComponents, whose events never pass the page's guard): for those
    the view is not drawn, as an old revision is not.

  `EditorHost` owns the `desk_published_view` assign: `nil` outside the
  perspective, else `%{key, doc, form, published?, unpublished_at}`, read
  again when the editor holds another version of the document.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.DocFooter
  alias BarkparkWeb.Studio.Desk.HistoryPanel
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.RevisionView

  @doc """
  The editor answered or the URL changed: in the published perspective, the
  published version of the edited document (read once per version the editor
  holds), or `nil`.
  """
  def follow(
        %{assigns: %{editing: {dataset, type, id}, editor_doc: %{} = doc} = assigns} = socket
      ) do
    form? = assigns[:editor_view] in [nil, :form]

    if form? and Panes.perspective(assigns[:desk_uri]) == :published do
      # An unpublish keeps the draft as it is: the editor's flag says it.
      key =
        {dataset, type, id, doc.doc_id, doc.rev, doc.updated_at, assigns[:editor_has_published]}

      case assigns[:desk_published_view] do
        %{key: ^key} -> socket
        _ -> assign(socket, :desk_published_view, read(socket, key, doc))
      end
    else
      assign(socket, :desk_published_view, nil)
    end
  end

  def follow(socket), do: assign(socket, :desk_published_view, nil)

  @doc """
  A `handle_info` hook step: on the desk's refresh tick (which follows every
  change it is told of, another tab's publish or unpublish too), the
  published version is read again while it is shown.
  """
  def on_info(:desk_refresh, %{assigns: %{desk_published_view: %{}}} = socket),
    do: socket |> assign(:desk_published_view, nil) |> follow()

  def on_info(_message, socket), do: socket

  defp read(%{assigns: assigns} = socket, {dataset, type, id, _, _, _, _} = key, doc) do
    opts = ScopeHelpers.scope_opts(socket)
    schema = assigns[:editor_schema]

    case Content.get_document(Content.published_id(id), type, dataset, opts) do
      {:ok, %{status: "published"} = pub} ->
        %{
          key: key,
          doc: pub,
          form: Content.doc_to_form(pub, schema),
          published?: true,
          unpublished_at: nil
        }

      _ ->
        stub = %{doc | title: nil, content: %{}}

        %{
          key: key,
          doc: stub,
          form: Content.doc_to_form(stub, schema),
          published?: false,
          unpublished_at: unpublished_at(id, type, dataset, opts)
        }
    end
  end

  # When the last publish-or-unpublish in the history was an unpublish.
  defp unpublished_at(id, type, dataset, opts) do
    id
    |> Content.list_revisions(type, dataset, opts)
    |> Enum.find(&(&1.action in ["publish", "unpublish"]))
    |> case do
      %{action: "unpublish", inserted_at: at} -> at
      _ -> nil
    end
  end

  @doc "Whether the page is in the published perspective over a document the form edits."
  def active?(assigns), do: match?(%{form: _}, assigns[:desk_published_view])

  @doc "Whether the published view is drawn in the form's place (no old revision named)."
  def shown?(assigns),
    do:
      active?(assigns) and not RevisionView.shown?(assigns) and not RevisionView.missing?(assigns)

  @doc "Whether a published version exists, as this view read it."
  def published?(assigns), do: match?(%{published?: true}, assigns[:desk_published_view])

  @doc """
  The page's assigns for drawing the Studio's form over the published
  version: its values, locked, no findings, no change bars, the classic form
  with every field and no dialog.
  """
  def shell_assigns(%{desk_published_view: %{doc: doc, form: form}} = assigns) do
    assigns
    |> assign(
      editor_doc: doc,
      editor_form: form,
      editor_schema: RevisionView.locked(assigns[:editor_schema]),
      editor_mode: :classic,
      validation_errors: %{},
      validation_warnings: %{},
      cross_violations: [],
      show_delete: false,
      show_unpublish_guard: false,
      desk_changes: nil
    )
    |> HistoryPanel.waiting()
  end

  # The published view's own write: Unpublish, which asks first.
  @writes ~w(unpublish confirm-unpublish)

  @doc """
  Whether `event` is refused because the published version is shown: every
  event that can write the open document but Unpublish. An old revision
  drawn in the view's place keeps its own Restore (`RevisionView`).
  """
  def refuses?(event, assigns) do
    active?(assigns) and event not in @writes and
      (event not in RevisionView.reads() or
         (event == "restore-revision" and not RevisionView.shown?(assigns)))
  end

  # The header menu's items that send an event and write nothing.
  @menu_reads ~w(desk-doc-copy)

  @doc """
  The header menu's items in the published view: only those that open
  something or link somewhere (History, Incoming references, the document's
  links), and Copy document, which copies the published version
  (`DocClip`).
  """
  def menu(items, assigns) do
    if active?(assigns),
      do: Enum.reject(items, &(is_binary(&1.event) and &1.event not in @menu_reads)),
      else: items
  end

  @doc "The footer's words: \"Last published 2h ago\", \"Unpublished just now\", or none."
  @spec status(map(), DateTime.t()) :: String.t()
  def status(assigns, now \\ DateTime.utc_now()) do
    case assigns[:desk_published_view] do
      %{published?: true, doc: %{updated_at: %DateTime{} = at}} ->
        gettext("Last published %{ago}", ago: DocFooter.ago(at, now))

      %{unpublished_at: %DateTime{} = at} ->
        gettext("Unpublished %{ago}", ago: DocFooter.ago(at, now))

      %{unpublished_at: %NaiveDateTime{} = at} ->
        gettext("Unpublished %{ago}",
          ago: DocFooter.ago(DateTime.from_naive!(at, "Etc/UTC"), now)
        )

      _ ->
        ""
    end
  end

  @doc """
  The form's title in the published view: the published version's, or, with
  none, the type's "New …" as TanStack's `docTitle` names a document that has
  no version to show.
  """
  def title(%{desk_published_view: %{published?: true, doc: %{title: title}}})
      when is_binary(title) and title != "",
      do: title

  def title(%{desk_published_view: %{published?: false}} = assigns) do
    type =
      case assigns[:editor_schema] do
        %{title: title} when is_binary(title) and title != "" -> title
        _ -> gettext("Untitled")
      end

    gettext("New %{type}", type: type)
  end

  def title(assigns), do: assigns[:page_title]
end
