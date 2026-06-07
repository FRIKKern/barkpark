defmodule BarkparkWeb.BulldocsIngestController do
  @moduledoc """
  Ingest endpoint for paperflow papers (convergence MVP, masterplan Figure 6).

  Matches the request the `paperflow/hooks/event-on-save.sh` mirror block
  POSTs. Two body shapes are accepted, both keyed by `slug`:

  NATIVE BLOCKS (preferred — renders in article mode at /papers/:slug):

      POST /v1/paperflow/papers
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>   (RequireIngestToken plug)
      Content-Type: application/json
      {
        "slug":       "2026-05-23-foo",
        "style":      "article",
        "blocks":     [ {"type":"heading","level":1,…}, … ],
        "source_doc": "specs/2026-05-23-foo.html",   // optional
        "event_type": "spec-written",                // optional
        "goal_id":    "bd-a1b2"                       // optional
      }

  RAW HTML (legacy fallback — stored verbatim, no article projection):

      POST /v1/paperflow/papers
      …
      { "slug": "2026-05-23-foo", "body_html": "<article>…</article>", … }

  Upserts the paper keyed by slug and broadcasts on its per-doc PubSub topic
  so any mounted `BulldocsLive` re-renders with no reload. Persists so a fresh
  mount renders the latest HTML. When `blocks` is present `Content.upsert_paper`
  renders the `body_html` cache from them in the article palette (style
  defaults to "article" on the blocks path); a `body_html`-only request stores
  the HTML verbatim as before.

  Wave 4 adds a second action, `apply_op/2`, for block-streaming:

      POST /v1/paperflow/papers/:slug/ops
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>   (RequireIngestToken plug)
      Content-Type: application/json
      { "op": "append-block", "block": { "id": "b1", "type": "paragraph", … } }

  It applies a single DocPatchOp to the paper's block list via
  `Content.apply_paper_block_op/2`, which renders the changed fragment,
  refreshes the HTML cache, bumps the rev, and broadcasts a `{:paper_block, …}`
  delta frame. Papers are stored as `documents` rows of type "paper" — the
  streaming protocol (topic, frames) is unchanged.

  M2 adds a BATCH shape on the same `/ops` route. When the body carries an
  `"ops"` array (`{"ops": [ <op>, … ]}`) the ops apply ATOMICALLY via
  `Content.apply_paper_block_ops/2` — all-or-nothing, one rev bump, one
  broadcast. The batch path returns a MINIMAL receipt
  (`{ok, slug, op_count, rev, block_ids}`, `fragment_html` suppressed). The
  single-op path (the body IS the op) is unchanged.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Tenancy

  # The five DocPatchOp discriminators (mirrors Barkpark.PortableDoc.Patch).
  @op_kinds ~w(append-block insert-after patch-block replace-block remove-block)

  # Native portable-doc blocks path (preferred). Renders in article mode so
  # the doc shows native typography at /papers/:slug. `style` defaults to
  # "article" since paperflow only mirrors article-grammar docs through this
  # endpoint; an explicit `style` in the body overrides it.
  def ingest(conn, %{"slug" => slug, "blocks" => blocks} = params)
      when is_binary(slug) and slug != "" and is_list(blocks) do
    attrs =
      %{
        "slug" => slug,
        "blocks" => blocks,
        "style" => params["style"] || "article",
        "source_doc" => params["source_doc"],
        "event_type" => params["event_type"],
        "goal_id" => params["goal_id"]
      }
      |> put_scope(conn, params)

    case Content.upsert_paper(attrs) do
      {:ok, paper} ->
        conn
        |> put_status(:ok)
        |> json(%{
          ok: true,
          slug: paper.doc_id,
          rev: to_string(get_in(paper.content, ["rev"])),
          liveview_path: "/papers/#{paper.doc_id}"
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_paper", message: "could not store paper"}})
    end
  end

  # Raw HTML path (legacy fallback). Stored verbatim — no article projection.
  def ingest(conn, %{"slug" => slug, "body_html" => body_html} = params)
      when is_binary(slug) and slug != "" and is_binary(body_html) do
    attrs =
      %{
        "slug" => slug,
        "body_html" => body_html,
        "style" => params["style"],
        "source_doc" => params["source_doc"],
        "event_type" => params["event_type"],
        "goal_id" => params["goal_id"]
      }
      |> put_scope(conn, params)

    case Content.upsert_paper(attrs) do
      {:ok, paper} ->
        conn
        |> put_status(:ok)
        |> json(%{
          ok: true,
          slug: paper.doc_id,
          # The monotonic streaming rev lives in content["rev"] (an integer);
          # stringify in the wire response so existing clients that read it as a
          # string keep working.
          rev: to_string(get_in(paper.content, ["rev"])),
          liveview_path: "/papers/#{paper.doc_id}"
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_paper", message: "could not store paper"}})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "malformed",
        message: "slug plus either blocks (list) or body_html (string) are required"
      }
    })
  end

  @doc """
  Apply ops to the paper at `:slug`. The endpoint accepts EITHER shape on the
  same route — the request body discriminates them:

    * **BATCH** — `{"ops": [ <op>, <op>, … ]}` (the `"ops"` key is a list).
      All ops apply ATOMICALLY (all-or-nothing) via
      `Content.apply_paper_block_ops/2`. On any op failure the paper is left
      UNCHANGED at its original rev and the error is returned. Returns the
      MINIMAL receipt by default — `{ok, slug, op_count, rev, block_ids}` —
      with `fragment_html` SUPPRESSED.

    * **SINGLE** (back-compat, unchanged) — the JSON body IS the op
      (`{"op": "append-block", "block": {…}}`). Applies one DocPatchOp via
      `Content.apply_paper_block_op/2` and returns the full per-op receipt
      `{ok, slug, op, rev, block_id, fragment_html, position}`.

  Common errors: 404 for an unknown slug; 422 for a malformed op or a patch
  failure (e.g. a block-not-found / type-mismatch on the target block list).
  """
  # BATCH path — `{"ops": [ … ]}`. Detected by the array-native `"ops"` key,
  # mirroring the mutate controller's `%{"mutations" => list}` discriminator.
  #
  # M3: an OPTIONAL `"ifRev"` at the body head is an optimistic-concurrency
  # guard. When present and != the paper's current rev, the batch is REJECTED
  # with 412 precondition_failed BEFORE any op applies (additive — absent ifRev
  # is the prior behaviour). Threaded into Content.apply_paper_block_ops/2 as the
  # `:if_rev` opt so the check happens inside the atomic load, not racily here.
  def apply_op(conn, %{"slug" => slug, "ops" => ops} = params) when is_list(ops) do
    cond do
      not Enum.all?(ops, &valid_op_shape?/1) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "malformed_op", message: "every op must name a known DocPatchOp"}
        })

      true ->
        op_opts =
          case Map.get(params, "ifRev") do
            nil -> []
            if_rev -> [if_rev: if_rev]
          end

        case Content.apply_paper_block_ops(slug, ops, Content.paper_default_dataset(), op_opts) do
          {:ok, result} ->
            # MINIMAL receipt — slug + op-count + new rev + affected block ids.
            # fragment_html is deliberately SUPPRESSED on the batch path.
            conn
            |> put_status(:ok)
            |> json(%{
              ok: true,
              slug: result.slug,
              op_count: result.op_count,
              rev: result.rev,
              block_ids: result.block_ids
            })

          {:error, :precondition_failed} ->
            conn
            |> put_status(:precondition_failed)
            |> json(%{
              error: %{
                code: "precondition_failed",
                message: "ifRev did not match the paper's current rev; no ops applied"
              }
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "no paper for slug #{slug}"}})

          {:error, {code, target, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: to_string(code),
                message: "#{op_kind} failed on #{inspect(target)}",
                op: op_kind,
                target: target
              }
            })

          {:error, {:invalid_op, _}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "an op could not be applied"}})

          {:error, _other} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "an op could not be applied"}})
        end
    end
  end

  def apply_op(conn, %{"slug" => slug} = params) do
    op = Map.delete(params, "slug")

    cond do
      not valid_op_shape?(op) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "malformed_op", message: "op must name a known DocPatchOp"}})

      true ->
        case Content.apply_paper_block_op(slug, op) do
          {:ok, result} ->
            conn
            |> put_status(:ok)
            |> json(%{
              ok: true,
              slug: slug,
              op: result.op_kind,
              rev: result.rev,
              block_id: result.block_id,
              fragment_html: result.fragment_html,
              position: result.position
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "no paper for slug #{slug}"}})

          {:error, {code, target, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: to_string(code),
                message: "#{op_kind} failed on #{inspect(target)}",
                op: op_kind,
                target: target
              }
            })

          {:error, {:invalid_op, _}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "op could not be applied"}})

          {:error, _other} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "op could not be applied"}})
        end
    end
  end

  # A minimally well-formed op: a map whose "op" is one of the five kinds.
  # Patch.apply_patch/2 does the deeper structural validation (required keys
  # per kind, id resolution); a shape failure there surfaces as a 422 above.
  defp valid_op_shape?(%{"op" => kind}) when kind in @op_kinds, do: true
  defp valid_op_shape?(_), do: false

  # W1.5-C: thread an OPTIONAL workspace/project into the upsert attrs so a
  # paper (and its emitted lifecycle event) lands in the goal's scope when
  # paperflow starts sending it. The scope may arrive as either a JSON body
  # field (`workspace`/`project`, OR the explicit id `workspace_id`/`project_id`)
  # or an HTTP header (`x-barkpark-workspace` / `x-barkpark-project`, carrying a
  # slug). Slugs are resolved to ids via Tenancy; an unknown slug resolves to no
  # scope key → upsert_paper's Default fallback applies (never a hard error, so
  # the flat paperflow ingest keeps working unchanged). When NO scope is given,
  # the attrs are returned untouched and Default fallback handles it.
  defp put_scope(attrs, conn, params) do
    {ws_id, project_id} = resolve_scope(conn, params)

    attrs
    |> maybe_put("workspace_id", ws_id)
    |> maybe_put("project_id", project_id)
  end

  # Resolve {workspace_id, project_id}. Precedence: explicit ids in the body win;
  # then a workspace/project slug (body field or header). project is only
  # resolved alongside a workspace. Returns {nil, nil} when nothing was provided
  # or a slug didn't resolve.
  defp resolve_scope(conn, params) do
    cond do
      is_binary(params["workspace_id"]) and params["workspace_id"] != "" ->
        {params["workspace_id"], blank_to_nil(params["project_id"])}

      true ->
        ws_slug = scope_value(conn, params, "workspace", "x-barkpark-workspace")
        resolve_from_slug(ws_slug, scope_value(conn, params, "project", "x-barkpark-project"))
    end
  end

  defp resolve_from_slug(nil, _project_slug), do: {nil, nil}

  defp resolve_from_slug(ws_slug, project_slug) do
    case Tenancy.get_workspace_by_slug(ws_slug) do
      %{id: ws_id} = ws -> {ws_id, resolve_project(ws, project_slug)}
      _ -> {nil, nil}
    end
  end

  defp resolve_project(_ws, nil), do: nil

  defp resolve_project(ws, project_slug) do
    case Tenancy.get_project(ws.slug, project_slug) do
      %{id: project_id} -> project_id
      _ -> nil
    end
  end

  # A scope value: prefer the JSON body field, fall back to the HTTP header.
  defp scope_value(conn, params, field, header) do
    blank_to_nil(params[field]) || header_value(conn, header)
  end

  defp header_value(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> blank_to_nil(value)
      _ -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
