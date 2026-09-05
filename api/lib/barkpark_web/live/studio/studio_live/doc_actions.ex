defmodule BarkparkWeb.Studio.StudioLive.DocActions do
  @moduledoc """
  Editor-header doc-actions registry, extracted from
  `BarkparkWeb.Studio.StudioLive` (Goal barkpark-cjs, s4).

  The editor-header action bar (Publish, Unpublish, Delete, History, Diff
  toggle, Show/Hide XML, Duplicate, Open another, plus schema-declared
  plugin actions like Export ONIX / Publish to Bokbasen) flows through
  `Barkpark.Plugins.Registry.collect_doc_actions/1`. The host builds its
  built-in list via `default_doc_actions/2`, passes it as `:baseline`, and
  the resolver chain (each plugin's `resolve_doc_actions/2`) can drop,
  reorder, or amend entries based on the live document payload.

  Every function takes the socket (or a raw assigns map) explicitly — no
  module state. StudioLive's handlers and render call straight in.
  """

  require Logger

  alias BarkparkWeb.ScopeHelpers

  # ── Schema-action helpers (Task #16 — action registry) ─────────────────────
  @doc false
  def schema_actions(nil), do: []

  def schema_actions(schema) do
    case Map.get(schema, :actions) || Map.get(schema, "actions") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Accepts either `%Phoenix.LiveView.Socket{}` (handle_event paths) or a
  # raw assigns map (render paths). Both flow through the same baseline +
  # resolver call so a plugin's filter applies whether the action is being
  # rendered or dispatched.
  @doc false
  def resolved_doc_actions(socket_or_assigns) do
    assigns = socket_to_assigns(socket_or_assigns)
    ctx = doc_actions_ctx(assigns)
    baseline = default_doc_actions(assigns, ctx)
    Barkpark.Plugins.Registry.collect_doc_actions(baseline: baseline, ctx: ctx)
  end

  defp socket_to_assigns(%{assigns: assigns}), do: assigns
  defp socket_to_assigns(assigns) when is_map(assigns), do: assigns

  defp doc_actions_ctx(assigns) do
    # `:workspace_id` threads the current workspace into the resolver ctx so
    # the doc-actions surfacing collector skips per-workspace-disabled plugins
    # (ssp-w1-plugin-enablement). Nil when no workspace is resolved → no filter.
    %{
      dataset: assigns[:dataset],
      doc_id: doc_id_from_assigns(assigns),
      doc_type: assigns[:editor_type],
      doc: assigns[:editor_doc],
      workspace_id: workspace_id_from_assigns(assigns)
    }
  end

  defp workspace_id_from_assigns(assigns) do
    case assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp doc_id_from_assigns(assigns) do
    case assigns[:editor_doc] do
      %{doc_id: doc_id} -> doc_id
      _ -> nil
    end
  end

  # Host's built-in editor-header doc-actions, seeded as `:baseline` for the
  # `resolve_doc_actions/2` resolver chain. The list mirrors what the editor
  # shell rendered as hardcoded HEEx before the refactor (History, Delete,
  # Publish/Unpublish, Show/Hide XML for books, Diff/Edit when a draft has a
  # published twin) plus the per-doc Duplicate / Open another buttons from
  # `:extra_actions` and the schema-declared actions (which the schema
  # author — including plugins like OnixEdit — registered via the schema's
  # `:actions` array). The conditional gating (draft vs published, book-only
  # XML toggle, diff-toggle availability) is expressed as the action being
  # in or out of the returned list.
  #
  # Order is rendering-order inside the editor-header `bp-overflow-menu`:
  # Publish/Unpublish (primary CTA leads) → Preview (the type's draft-mode
  # URL, only when the type declares one — see `preview_doc_action/2`) →
  # History → Show/Hide preview →
  # Diff toggle → Discard draft → Duplicate → Open another → View blast radius →
  # Delete (destructive, held to the TAIL — separated from the CTA so it is
  # out of the misclick zone) → schema actions.
  @doc false
  def default_doc_actions(assigns, _ctx) do
    assigns = socket_to_assigns(assigns)
    editor_doc = assigns[:editor_doc]
    editor_schema = assigns[:editor_schema]
    is_draft = assigns[:editor_is_draft] == true
    published_doc = assigns[:published_doc]
    content_preview_visible = assigns[:content_preview_visible] == true
    content_preview_rendered = assigns[:content_preview_rendered]
    diff_visible = assigns[:diff_visible] == true

    has_published_twin = is_draft and not is_nil(published_doc)
    has_content_preview = not is_nil(content_preview_rendered)

    base = [
      # Publish/Unpublish leads — the primary CTA is the first thing the
      # overflow menu offers, and no destructive action sits above it
      # (sup-w5-doc-actions-order: Delete used to sit between History and the
      # CTA, a misclick trap adjacent to the button the user actually wants).
      if is_draft do
        %{
          "name" => "publish",
          "label" => "Publish",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "publish",
            "class" => "btn btn-primary btn-sm",
            "icon" => "send"
          }
        }
      else
        %{
          "name" => "unpublish",
          "label" => "Unpublish",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "unpublish",
            "class" => "btn btn-sm",
            "icon" => "archive"
          }
        }
      end,
      # 'Preview' — a per-TYPE link to the page's draft-mode URL on the
      # consumer site (S9 criterion 4). Present ONLY when the type declares a
      # template at `desk.preview`; a type without one renders no Preview
      # button at all rather than a dead link to a guessed URL.
      #
      # HONEST SCOPE: this ships the AFFORDANCE, not the preview pipeline.
      # The link carries NO secret and mints NO token — the Next.js
      # draft-mode route (`js/packages/nextjs/src/draft-mode/index.ts`)
      # verifies an HMAC over `path`+`expiry`, and the drafts-readable token
      # tier that signing needs is S1 #7 (task-3a5a2a0662b0a661): every
      # mintable token is public-tier today. Until that tier lands the route
      # answers 401 `missing`. Signing here would mean inventing a tier this
      # row is explicitly forbidden to invent.
      preview_doc_action(editor_schema, editor_doc),
      %{
        "name" => "show-history",
        "label" => "History",
        "kind" => "event",
        "scope" => "editor_header",
        "opts" => %{
          "event" => "show-history",
          "class" => "btn btn-ghost btn-sm",
          "icon" => "history"
        }
      },
      if has_content_preview do
        %{
          "name" => "toggle-content-preview",
          "label" => if(content_preview_visible, do: "Hide preview", else: "Show preview"),
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "toggle-content-preview",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "onix-preview-toggle",
            "icon" => "code"
          }
        }
      end,
      if has_published_twin do
        %{
          "name" => "toggle-diff",
          "label" => if(diff_visible, do: "Edit", else: "Diff"),
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "toggle-diff",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "draft-diff-toggle",
            "icon" => "git-compare"
          }
        }
      end,
      if has_published_twin do
        %{
          "name" => "discard-draft",
          "label" => "Discard draft",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "discard-draft",
            "class" => "btn btn-ghost btn-sm",
            "style" => "color: var(--destructive);",
            "data_test_id" => "discard-draft",
            "icon" => "rotate-ccw"
          }
        }
      end,
      if editor_doc do
        %{
          "name" => "duplicate-doc",
          "label" => "Duplicate",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "duplicate-doc",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "duplicate-doc",
            "icon" => "copy"
          }
        }
      end,
      if editor_doc do
        %{
          "name" => "open-secondary-picker",
          "label" => "Open another",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "open-secondary-picker",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "open-secondary-picker",
            "icon" => "panel-right-open"
          }
        }
      end,
      # 'View blast radius' — opens the Canvas2D graph pane for THIS doc (Goal
      # ges/graph-edge-seam, FIX 2). Fires `view-graph`, which push_patches to
      # the reserved `graph/<doc_id>` nav segment PaneBuilder resolves into a
      # `view: :graph` editor. Without this affordance the GraphView half of
      # Phase 5 was unreachable (no nav anywhere produced a `graph/<id>` path).
      if editor_doc do
        %{
          "name" => "view-graph",
          "label" => "View blast radius",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "view-graph",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "view-graph",
            "icon" => "git-fork"
          }
        }
      end,
      # Delete sits LAST — separated from the CTA by every benign action so a
      # misclick near Publish can't destroy the doc. Still ghost + destructive
      # red (`color: var(--destructive)`) so it reads as dangerous, just out of
      # the hot zone (sup-w5-doc-actions-order).
      %{
        "name" => "delete-doc",
        "label" => "Delete",
        "kind" => "event",
        "scope" => "editor_header",
        "opts" => %{
          "event" => "delete-doc",
          "class" => "btn btn-ghost btn-sm",
          "style" => "color: var(--destructive);",
          "icon" => "trash-2"
        }
      }
    ]

    # Schema-declared actions land last. These are the entries plugins
    # already register today via SchemaDefinition `:actions` (e.g.
    # OnixEdit's `export_onix` link + `publish_to_bokbasen` modal). The
    # resolver chain runs over the combined list, so a plugin can still
    # filter its own schema-declared actions based on live doc state.
    schema_entries =
      editor_schema
      |> schema_actions()
      |> Enum.map(&Map.put(&1, "scope", "editor_header"))

    (base ++ schema_entries)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The per-type Preview link-action, or `nil` when the type declares no
  preview template.

  The template lives at the schema's `desk["preview"]` — a URL string in the
  same placeholder vocabulary the editor already interpolates for
  schema-declared `"link"` actions (`:slug` · `:id` · `:dataset` ·
  `:workspace` · `:project`), e.g.

      desk: %{"preview" => "https://site.example/api/draft?path=/blog/:slug"}

  Two things make it render, both required:

    * the type declares a non-empty template, AND
    * every placeholder the template uses can actually be filled — a
      template naming `:slug` against a document with no slug produces a
      URL that points at the wrong page, so no button is better than a
      wrong one (the same reasoning the row applies to the "may live in
      another workspace" hint).

  Interpolation itself is `BarkparkWeb.StudioComponents.Editor`'s — the
  action carries the raw template on `opts.href` exactly like an OnixEdit
  `"link"` action does.
  """
  def preview_doc_action(schema, doc) do
    with template when is_binary(template) <- preview_template(schema),
         true <- template != "",
         true <- placeholders_resolvable?(template, doc) do
      %{
        "name" => "preview",
        "label" => "Preview",
        "kind" => "link",
        "scope" => "editor_header",
        "opts" => %{
          "href" => template,
          "class" => "btn btn-ghost btn-sm",
          "data_test_id" => "preview-draft",
          "icon" => "external-link",
          # A preview leaves the Studio for the consumer site; opening it in
          # the same tab would tear down the LiveView (and any unsaved edit)
          # behind the editor's back.
          "target" => "_blank",
          "rel" => "noopener"
        }
      }
    else
      _ -> nil
    end
  end

  defp preview_template(nil), do: nil

  defp preview_template(schema) do
    desk = Map.get(schema, :desk) || Map.get(schema, "desk") || %{}

    case desk do
      %{} = d -> Map.get(d, "preview") || Map.get(d, :preview)
      _ -> nil
    end
  end

  # `:slug` is the only placeholder that can be UNFILLABLE — the others are
  # either always present (`:dataset`) or already resolve to "" by design for
  # every schema-declared link action (`:workspace` / `:project` on a flat
  # deployment), and `:id` is the doc's own identity.
  defp placeholders_resolvable?(template, doc) do
    not String.contains?(template, ":slug") or is_binary(doc_slug(doc))
  end

  @doc false
  def doc_slug(%{} = doc) do
    content = Map.get(doc, :content) || %{}

    candidates = [
      if(is_map(content), do: Map.get(content, "slug")),
      Map.get(doc, :slug_text)
    ]

    Enum.find(candidates, fn
      s when is_binary(s) -> s != ""
      _ -> false
    end)
  end

  def doc_slug(_), do: nil

  @doc false
  def find_resolved_doc_action(socket, name) do
    socket
    |> resolved_doc_actions()
    |> Enum.find(fn a -> Map.get(a, "name") == name end)
  end

  # Dispatch a named schema action to the plugin-owned handler. Each
  # plugin declares its handlers via the `Barkpark.Plugin.action_handlers/0`
  # callback (additive form) or `resolve_action_handlers/2` (resolver form);
  # `Plugins.Registry.collect_action_handlers/1` drives the resolver chain
  # seeded with the host's built-in handlers as `:baseline` (currently an
  # empty map — the host ships no built-in action handlers; the empty
  # map still flows so plugins can rely on `prev` being map-shaped).
  # Unknown names return a structured error so the caller can format a
  # flash instead of crashing.
  #
  # `:ctx` carries the dispatch identity (`%{dataset, doc_id, doc_type,
  # doc}`) sourced from `socket.assigns` so resolver plugins can return a
  # different handler — or no handler at all — depending on the live
  # document. `doc_type` and `doc` are read straight off
  # `:editor_type` / `:editor_doc`; modal dispatch always targets the
  # currently-open editor doc, so the assigns are guaranteed in scope.
  @doc false
  def dispatch_action(socket, name, doc_id, dataset, mode) do
    ctx = action_handler_ctx(socket, doc_id, dataset)

    handlers =
      Barkpark.Plugins.Registry.collect_action_handlers(
        baseline: default_action_handlers(ctx),
        ctx: ctx
      )

    case Map.get(handlers, name) do
      handler when is_function(handler, 3) ->
        safe_dispatch(handler, name, doc_id, dataset, mode)

      _ ->
        {:error, {:unknown_action, name}}
    end
  end

  # Guards the plugin-owned handler call the same way
  # `Plugins.Registry.safe_resolver_call/4` guards resolver calls (see
  # `lib/barkpark/plugins/registry/resolver_chain.ex`) — a raising or
  # throwing action handler (OnixEdit's XML / Bokbasen IO can genuinely
  # raise) must not take down the dispatching LiveView process.
  # `Logger.warning` is mandatory here: a rescue with no log trades a crash
  # for a silent disappearance, which is worse.
  defp safe_dispatch(handler, name, doc_id, dataset, mode) do
    try do
      handler.(doc_id, dataset, mode)
    rescue
      e ->
        Logger.warning(
          "BarkparkWeb.Studio.StudioLive.DocActions: action #{inspect(name)} handler raised — " <>
            Exception.message(e)
        )

        {:error, {:handler_raised, Exception.message(e)}}
    catch
      kind, reason ->
        Logger.warning(
          "BarkparkWeb.Studio.StudioLive.DocActions: action #{inspect(name)} handler #{kind} — " <>
            inspect(reason)
        )

        {:error, {:handler_raised, "#{kind} #{inspect(reason)}"}}
    end
  end

  # Host's built-in action handlers, seeded as `:baseline` for the
  # `resolve_action_handlers/2` resolver chain. Currently empty — every
  # production action handler today is plugin-owned (OnixEdit) — but
  # extracted to its own fn so the chain is wired symmetrically and a
  # future host-owned action lands here without touching the dispatch
  # call site.
  defp default_action_handlers(_ctx), do: %{}

  # Build the resolver `:ctx` for `collect_action_handlers/1`. The doc
  # type and doc payload come directly off `socket.assigns` — the modal
  # dispatch always fires against the currently-open editor pane, so
  # `:editor_type` / `:editor_doc` are the right values without a
  # separate DB lookup.
  defp action_handler_ctx(socket, doc_id, dataset) do
    %{
      dataset: dataset,
      doc_id: doc_id,
      doc_type: socket.assigns[:editor_type],
      doc: socket.assigns[:editor_doc],
      # barkpark-zdvi — the tenancy scope of the dispatching Studio session.
      # Resolver plugins (OnixEdit) close over this so a scope-aware action
      # (publish/dry-run) reads only THIS workspace/project's document and
      # threads the same scope into any Oban job it enqueues. Empty when the
      # socket carries no workspace/project assign (back-compat → Default
      # resolution).
      scope: ScopeHelpers.scope_opts(socket)
    }
  end

  # Pull the canonical doc_id for the currently-open editor. Modal actions
  # always target the editor's open doc — there's no multi-select dispatch.
  @doc false
  def doc_id_for_action(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: doc_id} -> doc_id
      _ -> nil
    end
  end

  @doc false
  def preview_from_result({:ok, %{kind: :xml} = preview}), do: preview

  def preview_from_result({:error, reason}),
    do: %{kind: :error, message: format_action_error(reason)}

  def preview_from_result(_), do: nil

  @doc false
  def format_action_error({:xsd_invalid, reasons}) when is_list(reasons) do
    "ONIX failed XSD validation: " <> Enum.join(Enum.take(reasons, 3), "; ")
  end

  def format_action_error(:no_doc), do: "No document loaded"

  def format_action_error({:unknown_action, name}), do: "Unknown action: #{name}"

  def format_action_error({:handler_raised, msg}), do: "Action failed: #{msg}"

  def format_action_error(other), do: inspect(other, limit: 100)
end
