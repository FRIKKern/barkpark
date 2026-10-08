defmodule BarkparkWeb.DocumentActionsController do
  @moduledoc """
  `GET/POST /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id/actions[/:name]`
  (task-bd311f4b5ea2b3b8).

  The product-era core rule (docs/contracts/product-era.md): anything Studio
  can do, the API can do too. Studio's editor-header action bar resolves its
  live action list through `BarkparkWeb.Studio.StudioLive.DocActions` and
  dispatches a named one through `DocActions.dispatch_action/5` — both
  reachable ONLY from the LiveView socket before this route. `GET
  /v1/schemas/:dataset` carries just the schema's STATIC `actions` array,
  never the resolver-filtered live list (a plugin can drop, reorder or amend
  entries per the live document — OnixEdit hides `publish_to_bokbasen` while a
  Bokbasen submission is pending, a state the static array never reaches).

  This controller calls the EXACT same two entry points LiveView calls,
  seeded from a `%Plug.Conn{}` instead of a `%Phoenix.LiveView.Socket{}` —
  `DocActions.resolved_doc_actions/1` and `.dispatch_action/5` both only ever
  read `.assigns` off whatever they're given (`socket.assigns[:editor_type]`,
  etc.), and `BarkparkWeb.ScopeHelpers.scope_opts/1` has a `%Plug.Conn{}`
  clause already, so a conn carrying the same assign keys a LiveView mount
  would set is indistinguishable to either function.

  `GET .../actions` lists every resolved action (built-in UI events included —
  `publish`, `delete-doc`, etc. — exactly as the editor-header menu would
  render them) as `{name, label, kind, modal, icon, href}`. `POST
  .../actions/:name` DISPATCHES one, but only ever succeeds for a plugin-owned
  action with a registered handler (`Barkpark.Plugins.Registry
  .collect_action_handlers/1`) — the host's own `default_action_handlers/1` is
  empty, so a built-in UI action like `"publish"` answers 404 `unknown_action`
  here exactly as `dispatch_action/5` would answer it from a LiveView
  `phx-click`: those already have their own dedicated HTTP routes elsewhere
  (`POST /v1/data/mutate`, etc.), and this generic dispatch path was never
  wired to run them.

  `:scoped_admin` — the same workspace owner/admin role gate Studio's own
  editor mount enforces — is "admin tier as in LiveView" from the row, not a
  new tier invented for this route.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Studio.StudioLive.DocActions

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def index(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id}) do
    case load_doc_assigns(conn, dataset, type, doc_id) do
      {:ok, conn} ->
        actions = conn |> DocActions.resolved_doc_actions() |> Enum.map(&public_action/1)
        json(conn, %{actions: actions})

      {:error, reason} ->
        ErrorResponse.emit(conn, {:error, reason})
    end
  end

  def dispatch(
        conn,
        %{
          "dataset" => dataset,
          "type" => type,
          "doc_id" => doc_id,
          "name" => name
        } = params
      ) do
    with {:ok, mode} <- parse_mode(params["mode"]),
         {:ok, conn} <- load_doc_assigns(conn, dataset, type, doc_id) do
      # `load_doc_assigns/4` already resolved the draft-first target id onto
      # `conn.assigns[:editor_doc].doc_id` — the SAME id `dispatch_action/5`
      # must act on, not necessarily the bare id the URL carries (a request
      # against a published doc with an open draft edits the draft, exactly
      # like the Studio editor does).
      target_id = conn.assigns.editor_doc.doc_id

      conn
      |> DocActions.dispatch_action(name, target_id, dataset, mode)
      |> respond_dispatch(conn, mode)
    else
      {:error, :bad_mode} ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "malformed_mode",
          ~s(mode must be "dryrun" or "real")
        )

      {:error, reason} ->
        ErrorResponse.emit(conn, {:error, reason})
    end
  end

  defp respond_dispatch({:error, {:unknown_action, _} = reason}, conn, _mode) do
    ErrorResponse.emit_custom(
      conn,
      :not_found,
      "unknown_action",
      DocActions.format_action_error(reason)
    )
  end

  # A dry-run failure (e.g. ONIX failing XSD validation) is the PREVIEW's own
  # answer, not a malformed request — 200, same as `preview_from_result/1`
  # shapes a LiveView flash from the identical error tuple instead of a crash.
  defp respond_dispatch({:error, reason}, conn, :dryrun) do
    json(conn, %{preview: %{kind: "error", message: DocActions.format_action_error(reason)}})
  end

  defp respond_dispatch({:error, reason}, conn, :real) do
    ErrorResponse.emit_custom(
      conn,
      :unprocessable_entity,
      "action_failed",
      DocActions.format_action_error(reason)
    )
  end

  defp respond_dispatch({:ok, result}, conn, :dryrun) do
    json(conn, %{preview: json_safe(result)})
  end

  defp respond_dispatch({:ok, result}, conn, :real) do
    json(conn, %{result: json_safe(result)})
  end

  # A handler returning anything other than {:ok, _} / {:error, _} (bare
  # `:ok`, a raw map) — same catch-all `confirm_modal_real/1` guards against
  # in the LiveView handler, so a loose plugin contract can't 500 here either.
  defp respond_dispatch(other, conn, _mode) do
    json(conn, %{result: json_safe(other)})
  end

  defp parse_mode("dryrun"), do: {:ok, :dryrun}
  defp parse_mode("real"), do: {:ok, :real}
  defp parse_mode(_), do: {:error, :bad_mode}

  # Resolve schema + draft-first document, then assign exactly the keys
  # `DocActions.resolved_doc_actions/1` and the `dispatch_action/5` call chain
  # read off `.assigns` for a LiveView-mounted editor —
  # `:dataset`/`:editor_type`/`:editor_doc`/`:editor_schema`/
  # `:editor_is_draft`/`:published_doc`/`:current_workspace`. The last one is
  # already set by `ResolveWorkspace` upstream in the `:scoped_api` pipeline;
  # everything else is set here.
  defp load_doc_assigns(conn, dataset, type, doc_id) do
    opts = scope_opts(conn)
    target_id = edit_target(doc_id, type, dataset, opts)

    with {:ok, schema} <- Content.get_schema(type, dataset, opts),
         {:ok, doc} <- Content.get_document(target_id, type, dataset, opts) do
      is_draft = Content.draft?(doc.doc_id)

      conn =
        conn
        |> Plug.Conn.assign(:dataset, dataset)
        |> Plug.Conn.assign(:editor_type, type)
        |> Plug.Conn.assign(:editor_doc, doc)
        |> Plug.Conn.assign(:editor_schema, schema)
        |> Plug.Conn.assign(:editor_is_draft, is_draft)
        |> Plug.Conn.assign(:published_doc, published_twin(doc, type, dataset, is_draft, opts))

      {:ok, conn}
    else
      {:error, _} = err -> err
    end
  end

  # Draft-first lookup, byte-identical idiom to
  # `BarkparkWeb.DocumentOpsController`'s `edit_target/4`: a bare id edits its
  # OWN draft when one exists, exactly as the Studio editor does and as
  # `?perspective=raw` reads it.
  defp edit_target("drafts." <> _ = doc_id, _type, _dataset, _opts), do: doc_id

  defp edit_target(doc_id, type, dataset, opts) do
    draft_id = "drafts." <> doc_id

    case Content.get_document(draft_id, type, dataset, opts) do
      {:ok, _draft} -> draft_id
      _ -> doc_id
    end
  end

  defp published_twin(_doc, _type, _dataset, false, _opts), do: nil

  defp published_twin(doc, type, dataset, true, opts) do
    case Content.get_document(Content.published_id(doc.doc_id), type, dataset, opts) do
      {:ok, pub} -> pub
      _ -> nil
    end
  end

  # name/label/kind are always top-level on every action map
  # (`default_doc_actions/2`'s built-ins AND a plugin's schema-declared
  # entries). `modal` is top-level-only (a schema modal action's confirm copy
  # — built-ins carry no modal). `icon`/`href` are top-level on a
  # schema-declared action but live under `"opts"` on a built-in one
  # (`default_doc_actions/2`'s own `%{"opts" => %{"icon" => ..., "href" =>
  # ...}}` shape) — `field/2` checks both so one serializer covers both
  # action families the resolver chain can hand back.
  defp public_action(action) do
    %{
      name: Map.get(action, "name"),
      label: Map.get(action, "label"),
      kind: Map.get(action, "kind"),
      modal: Map.get(action, "modal"),
      icon: field(action, "icon"),
      href: field(action, "href")
    }
  end

  defp field(action, key), do: Map.get(action, key) || get_in(action, ["opts", key])

  # A plugin action handler's result/preview is arbitrary plugin-owned data
  # (OnixEdit's dry-run carries raw XML + a summary map; its real mode carries
  # an `%Oban.Job{}`, which has no `Jason.Encoder`). This recursively reduces
  # any struct to a plain string-keyed map so the generic dispatch endpoint
  # never 500s on a plugin's own result shape, win or lose.
  defp json_safe(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp json_safe(%Date{} = v), do: Date.to_iso8601(v)

  defp json_safe(%{__struct__: _} = v),
    do: v |> Map.from_struct() |> Map.delete(:__meta__) |> json_safe()

  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {json_safe_key(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_pid(v) or is_reference(v) or is_function(v), do: inspect(v)
  defp json_safe(v), do: v

  defp json_safe_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_safe_key(k), do: k
end
