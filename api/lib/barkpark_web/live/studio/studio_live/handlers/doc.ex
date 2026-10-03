defmodule BarkparkWeb.Studio.StudioLive.Handlers.Doc do
  @moduledoc """
  Publish / unpublish (blast-radius guard) / duplicate. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def publish(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      content = Content.build_content(socket.assigns.editor_form, socket.assigns[:editor_schema])
      title = Map.get(socket.assigns.editor_form, "title", doc.title)

      # Errors gate the publish; warnings (schema `"level": "warning"`, Gyldendal
      # parity E1.6) ride along in the assign so the bar still shows them after
      # a successful publish — Sanity's warning nags, it never blocks.
      %{errors: errs, warnings: warns} =
        case socket.assigns[:editor_schema] do
          # No resolved schema: the pre-existing dataset lookup, errors only.
          nil ->
            case Content.validate_document(type, title, content, socket.assigns.dataset) do
              {:error, errs} -> %{errors: errs, warnings: %{}}
              _ -> %{errors: %{}, warnings: %{}}
            end

          schema ->
            # The tree reading (E1.11): nested errors gate the publish just
            # like top-level ones, nested warnings only nag.
            Barkpark.Content.Validation.check_tree(content, title, schema)
        end

      # The workspace's language, once, before any render site (E7, #87).
      errs = BarkparkWeb.StudioLocale.localize_findings(errs)
      warns = BarkparkWeb.StudioLocale.localize_findings(warns)

      socket = assign(socket, validation_warnings: warns)

      case errs do
        errs when errs != %{} ->
          {:noreply,
           socket
           |> assign(validation_errors: errs)
           |> put_flash(:error, gettext("Fix validation errors before publishing"))}

        _ when type == "tag" ->
          if generated_unpublished_tag?(doc, socket),
            do: publish_tag_under_name(socket, doc, title, content),
            else: publish_open_doc(socket)

        _ ->
          publish_open_doc(socket)
      end
    else
      # Same rule as the refusal arms above: an ERROR arm of this case already
      # flashes, so a press that never ran must not answer with silence.
      {:noreply, put_flash(socket, :error, "Nothing to publish — open a document first")}
    end
  end

  defp publish_open_doc(socket) do
    opts = Shared.hook_opts(socket)

    Shared.do_action(
      socket,
      fn d, t ->
        Content.publish_document(
          Content.published_id(d.doc_id),
          t,
          socket.assigns.dataset,
          opts
        )
      end,
      "Published"
    )
  end

  # ── [studio-tag-name-is-the-id] task-655768f4fa3c9fed ─────────────────────
  #
  # The publish wall registers a tag by its DOCUMENT ID, never its title
  # (`Barkpark.Content.TagRegistry`), but Studio's "+" births every document
  # with a generated id (`Writer.generate_id/1`: `tag-<16 hex>`), and nothing
  # in Studio can rename an id. So a tag made in Studio and titled
  # "editorial" published fine and was then refused by name on every document
  # that used it. The first publish of such a tag publishes it under the name
  # its title gives instead, and removes the generated draft.
  @generated_tag_id ~r/\Atag-[0-9a-f]{16}\z/
  @tag_name ~r/\A[a-z0-9-]+\z/

  defp generated_unpublished_tag?(doc, socket) do
    pub_id = Content.published_id(doc.doc_id)

    Regex.match?(@generated_tag_id, pub_id) and
      match?(
        {:error, _},
        Content.get_document(pub_id, "tag", socket.assigns.dataset, Shared.hook_opts(socket))
      )
  end

  defp publish_tag_under_name(socket, doc, title, content) do
    dataset = socket.assigns.dataset
    opts = Shared.hook_opts(socket)
    pub_id = Content.published_id(doc.doc_id)
    title = String.trim(to_string(title || ""))
    name = Barkpark.Tenancy.slugify(title)

    cond do
      title in ["", "Untitled"] or not Regex.match?(@tag_name, name) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Name the tag before publishing. Documents use the tag by a name made from its title " <>
             "(lowercase letters, digits and hyphens), so the title needs at least one letter or digit."
         )}

      tag_name_taken?(name, dataset, opts) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A tag named “#{name}” already exists. Open that tag to change it, or give this one a different title."
         )}

      true ->
        attrs = %{"doc_id" => name, "title" => title, "content" => content}

        with {:ok, _draft} <- Content.create_document("tag", attrs, dataset, opts),
             {:ok, _published} <- Content.publish_document(name, "tag", dataset, opts) do
          _ = Content.discard_draft(pub_id, "tag", dataset, opts)
          path = rekeyed_path(socket.assigns.nav_path, pub_id, name)

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Published tag “#{name}”. Documents and tasks use it by that name."
           )
           |> push_patch(to: Shared.studio_path(socket, path, dataset))}
        else
          error ->
            _ = Content.discard_draft(name, "tag", dataset, opts)

            {:noreply,
             put_flash(
               socket,
               :error,
               "Publish failed: the tag “#{name}” could not be saved (#{inspect(error)}). Your draft is unchanged."
             )}
        end
    end
  end

  defp tag_name_taken?(name, dataset, opts) do
    Enum.any?([name, Content.draft_id(name)], fn id ->
      match?({:ok, _}, Content.get_document(id, "tag", dataset, opts))
    end)
  end

  defp rekeyed_path(nav_path, old_id, new_id) when is_list(nav_path) do
    if List.last(nav_path) == old_id,
      do: List.replace_at(nav_path, -1, new_id),
      else: nav_path
  end

  def unpublish(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      published_id = Content.published_id(doc.doc_id)

      refs =
        Content.Graph.reverse_referencers(
          published_id,
          [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)
        )

      if refs == [] do
        Shared.do_unpublish(socket)
      else
        {:noreply, assign(socket, show_unpublish_guard: true, unpublish_refs: refs)}
      end
    else
      {:noreply, put_flash(socket, :error, "Nothing to unpublish — open a document first")}
    end
  end

  def close_unpublish_guard(socket) do
    {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
  end

  def confirm_unpublish(params, socket) do
    doc = socket.assigns[:editor_doc]

    if doc && socket.assigns[:editor_type] do
      socket =
        if params["disconnect"] == "true" do
          Content.disconnect_references(
            doc.doc_id,
            socket.assigns.dataset,
            ScopeHelpers.scope_opts(socket)
          )

          socket
        else
          socket
        end

      socket
      |> assign(show_unpublish_guard: false, unpublish_refs: [])
      |> Shared.do_unpublish()
    else
      {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
    end
  end

  def duplicate_doc(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.clone_document(doc, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
        {:ok, new_doc} ->
          pub_id = Content.published_id(new_doc.doc_id)
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> put_flash(:info, "Duplicated as #{pub_id}")
           |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "Duplicate cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to duplicate")}
      end
    else
      {:noreply, put_flash(socket, :error, "Nothing to duplicate — open a document first")}
    end
  end
end
