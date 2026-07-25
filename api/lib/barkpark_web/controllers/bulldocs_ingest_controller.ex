defmodule BarkparkWeb.BulldocsIngestController do
  @moduledoc """
  Ingest endpoint for papers (convergence MVP, masterplan Figure 6).

  Two body shapes are accepted, both keyed by `slug`:

  NATIVE BLOCKS (preferred — renders in article mode at /papers/:slug):

      POST /v1/plugins/bulldocs/papers
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

      POST /v1/plugins/bulldocs/papers
      …
      { "slug": "2026-05-23-foo", "body_html": "<article>…</article>", … }

  Upserts the paper keyed by slug and broadcasts on its per-doc PubSub topic
  so any mounted `BulldocsLive` re-renders with no reload. Persists so a fresh
  mount renders the latest HTML. When `blocks` is present `Content.upsert_paper`
  renders the `body_html` cache from them in the article palette (style
  defaults to "article" on the blocks path); a `body_html`-only request stores
  the HTML verbatim as before.

  Wave 4 adds a second action, `apply_op/2`, for block-streaming:

      POST /v1/plugins/bulldocs/papers/:slug/ops
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

  lvw-t4 adds the AI-proposes loop, `propose/2`:

      POST /v1/plugins/bulldocs/papers/:slug/proposals
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>   (RequireIngestToken plug)
      Content-Type: application/json
      {
        "ops":    [ {"op":"append-block","block":{"id":"prop-1", …}}, … ],
        "source": {"doc_id":"kpi-1","agent":"fable-w12","note":"optional"}
      }

  INSERT-ONLY ops (`append-block` / `insert-after`, each block carrying an
  explicit id — the idempotency key) land on the paper's `drafts.<slug>` twin
  with a mandatory provenance edge; the PUBLISHED revision is never written.
  Approval is the EXISTING draft→publish gate (`{"publish":{"id":"<slug>",
  "type":"paper"}}` on `/v1/data/mutate/:dataset`); rejection is
  `discardDraft`. See `Barkpark.Content.Papers.Proposals`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{Errors, Warnings}
  alias Barkpark.Tenancy

  # The five DocPatchOp discriminators (mirrors Barkpark.PortableDoc.Patch).
  @op_kinds ~w(append-block insert-after patch-block replace-block remove-block)

  # Learn-pointer advisory for the legacy body_html leg (authoring-excellence
  # ae-ingest-learn-pointer). The errors-as-instructions pattern teaches what
  # broke; this teaches WHERE THE STANDARDS LIVE at the point of use. A producer
  # who reaches for opaque body_html gets a NON-BLOCKING nudge toward the native
  # `blocks` grammar and the doctrine papers — advisory only, never a 4xx
  # (charter D5). Rides the existing Warnings channel opened by the wall wiring
  # (D36/D42): this is that pipe's FIRST content-shape consumer, not a duplicate.
  @body_html_learn_code "legacy_body_html"
  @body_html_learn_message "This paper was ingested as opaque body_html; the preferred path is a native `blocks` list (in-canvas editing, ~50 block types). Learn the block vocabulary and composition grammar in the doctrine papers /papers/portabledoc-doctrine and /papers/composition-doctrine-plan, then re-ingest with `blocks`."

  # Native portable-doc blocks path (preferred). Renders in article mode so
  # the doc shows native typography at /papers/:slug. `style` defaults to
  # "article" since this endpoint only ingests article-grammar docs;
  # an explicit `style` in the body overrides it.
  def ingest(conn, params) do
    case params do
      %{"slug" => slug, "blocks" => blocks} = accepted
      when is_binary(slug) and slug != "" and is_list(blocks) ->
        if valid_ingest_text?(accepted) do
          ingest_blocks(conn, slug, blocks, accepted)
        else
          invalid_text(conn)
        end

      %{"slug" => slug, "body_html" => body_html} = accepted
      when is_binary(slug) and slug != "" and is_binary(body_html) ->
        if valid_ingest_text?(accepted) do
          ingest_html(conn, slug, body_html, accepted)
        else
          invalid_text(conn)
        end

      _malformed ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            code: "malformed",
            message: "slug plus either blocks (list) or body_html (string) are required"
          }
        })
    end
  end

  defp ingest_blocks(conn, slug, blocks, params) do
    attrs =
      %{
        "slug" => slug,
        "blocks" => blocks,
        "style" => params["style"] || "article",
        "source_doc" => params["source_doc"],
        "event_type" => params["event_type"],
        "goal_id" => params["goal_id"],
        # Label-spine passthrough (charter D26): ingest ENFORCES the publish
        # wall (fresh papers are never exempt), so a compliant producer must
        # be able to send its weighted tags + description through this
        # whitelist — dropping them made every honest POST structurally
        # unable to pass. nil (absent params) adds nothing.
        "tags" => params["tags"],
        "description" => params["description"]
      }
      |> put_scope(conn, params)

    # Open the advisory channel before the wall runs (authoring-excellence
    # D36/D42) — mirrors MutateController. The wall's advise band (soft-dup
    # similarity 0.30–0.55, off-norm tag count) queues [{code, severity,
    # message}] via Warnings.put/3 while upsert_paper writes; with_warnings/1
    # drains it into the SUCCESS body below. Reset first so a prior request on a
    # reused test process can never leak advisories in.
    Warnings.reset()

    case Content.upsert_paper(attrs) do
      {:ok, paper} ->
        body = %{
          ok: true,
          slug: paper.doc_id,
          rev: to_string(get_in(paper.content, ["rev"])),
          liveview_path: "/papers/#{paper.doc_id}",
          # ADDITIVE (P4) — the canonical scoped reader URL when the paper's
          # tenancy resolves; liveview_path stays byte-identical forever
          # (locked paper-ingest contract).
          scoped_liveview_path: scoped_liveview_path(paper)
        }

        conn
        |> put_status(:ok)
        |> json(with_warnings(body))

      # A server veto from BlockOps.upsert_paper arrives as {:halted, reason} —
      # the M1 template halt (locked-block / structure) and the hollow-body
      # quality gate (p-quality-gate) alike. The reason IS the human-readable
      # violation; surface it VERBATIM with 409 rather than flattening it into
      # the generic invalid_paper below.
      {:error, {:halted, reason}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "halted", message: reason}})

      # Publish-wall rejections (authoring-excellence D27). Once the upsert_paper
      # mount (D26) lands, a walled paper birth surfaces as a RAW wall tuple —
      # route each through the shared v1 error envelope so the ingest caller gets
      # field/rule/fix + a machine hint and can retry: label_spine 422,
      # unknown_tag 422, duplicate_of 409. These sit ABOVE the changeset
      # catch-all so a wall tuple is NEVER demoted to the generic invalid_paper,
      # and they are NOT flattened into {:halted, _} (that would mis-route the
      # 422s to the 409 halted head). Pure routing — every envelope + @hints
      # entry already lives in Barkpark.Content.Errors (errors.ex:289/:316/:330).
      {:error, {:label_spine, _}} = err ->
        render_error(conn, err)

      {:error, {:unknown_tag, _}} = err ->
        render_error(conn, err)

      {:error, {:duplicate_of, _}} = err ->
        render_error(conn, err)

      {:error, changeset} ->
        invalid_paper_error(conn, changeset)
    end
  end

  # Raw HTML path (legacy fallback). Stored verbatim — no article projection.
  defp ingest_html(conn, slug, body_html, params) do
    attrs =
      %{
        "slug" => slug,
        "body_html" => body_html,
        "style" => params["style"],
        "source_doc" => params["source_doc"],
        "event_type" => params["event_type"],
        "goal_id" => params["goal_id"],
        # Label-spine passthrough (charter D26) — see the blocks head above;
        # the legacy HTML leg is walled identically.
        "tags" => params["tags"],
        "description" => params["description"]
      }
      |> put_scope(conn, params)

    # Advisory channel — see the blocks head (authoring-excellence D36/D42).
    Warnings.reset()

    # Learn-pointer: the body_html leg is the legacy fallback. Queue a
    # NON-BLOCKING advisory (first, so it leads the drained list) naming the
    # preferred blocks path + the doctrine papers. It rides the SUCCESS envelope
    # via with_warnings/1; an error path drops the queue, so a rejected ingest
    # never carries it. Advisory only — never promoted to a 4xx (charter D5).
    Warnings.put(@body_html_learn_code, @body_html_learn_message)

    case Content.upsert_paper(attrs) do
      {:ok, paper} ->
        body = %{
          ok: true,
          slug: paper.doc_id,
          # The monotonic streaming rev lives in content["rev"] (an integer);
          # stringify in the wire response so existing clients that read it as a
          # string keep working.
          rev: to_string(get_in(paper.content, ["rev"])),
          liveview_path: "/papers/#{paper.doc_id}",
          # ADDITIVE (P4) — see scoped_liveview_path/1.
          scoped_liveview_path: scoped_liveview_path(paper)
        }

        conn
        |> put_status(:ok)
        |> json(with_warnings(body))

      # Server veto (template / hollow-body gate) — surface the reason
      # VERBATIM (see the blocks path).
      {:error, {:halted, reason}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "halted", message: reason}})

      # Publish-wall rejections (authoring-excellence D27) — see the blocks path
      # above. Same three raw wall tuples, routed through render_error/2 above
      # the changeset catch-all.
      {:error, {:label_spine, _}} = err ->
        render_error(conn, err)

      {:error, {:unknown_tag, _}} = err ->
        render_error(conn, err)

      {:error, {:duplicate_of, _}} = err ->
        render_error(conn, err)

      {:error, changeset} ->
        invalid_paper_error(conn, changeset)
    end
  end

  # ── Sessions (session-handoff Task 3) ──────────────────────────────────────
  # A "session" is the second member of the blocks-doc whitelist
  # (`Content.blocks_type?/1` — `["paper", "session"]`), so its ingest/show/ops
  # actions mirror the paper leg above but call the GENERALIZED
  # `Content.upsert_blocks_doc/3`, `get_blocks_doc/4`, `apply_document_block_op/5`
  # instead of the paper-only functions. Unlike a paper, a session write is
  # NEVER walled (`AuthoringWall`'s `@walled_types` is `~w(paper task)`), so the
  # {:label_spine,_}/{:unknown_tag,_}/{:duplicate_of,_}/{:halted,_} tuples
  # below are dead code for "session" today — kept for shape-parity with the
  # paper leg so a future walled non-paper type costs nothing here.
  #
  # ONLY these keys are ever taken from the request body (never raw params) —
  # this whitelist is the mitigation for the fact that `@blocks_doc_reserved_attrs`
  # (block_ops.ex) does not itself reserve derived keys (`body_html`,
  # `body_html_sv`, `preview`, `main_tag`); none of those appear here.
  @session_keys ~w(slug title blocks style tags description harness session_uuid cwd
                    machine git_head git_branch started_at ended_at transcript status)

  @doc """
  Upsert (create or update) a session — the metadata-only-allowed blocks-doc
  twin of `ingest/2`. `blocks` is OPTIONAL: on create a missing `blocks` key
  defaults to `[]` inside `Content.upsert_blocks_doc/3`; on update a missing
  key preserves the existing blocks/body_html (session-handoff Task 2's
  contract) — this controller must NOT pre-seed a `"blocks"` default itself,
  or every metadata-only update would wipe the stored blocks to `[]`.
  """
  def ingest_session(conn, %{"slug" => slug} = params) when is_binary(slug) and slug != "" do
    attrs =
      params
      |> Map.take(@session_keys)
      |> put_scope(conn, params)

    Warnings.reset()

    case Content.upsert_blocks_doc("session", attrs) do
      {:ok, doc} ->
        conn
        |> put_status(:ok)
        |> json(with_warnings(%{ok: true, slug: doc.doc_id}))

      {:error, {:halted, reason}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "halted", message: reason}})

      {:error, {:label_spine, _}} = err ->
        render_error(conn, err)

      {:error, {:unknown_tag, _}} = err ->
        render_error(conn, err)

      {:error, {:duplicate_of, _}} = err ->
        render_error(conn, err)

      {:error, changeset} ->
        invalid_paper_error(conn, changeset)
    end
  end

  def ingest_session(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: "slug required"})

  @doc """
  Read a session by slug — the same visibility tier as the writes
  (`auth: :ingest`; the doc is also readable via the public paper routes once
  published). 404 when the slug doesn't resolve to a "session" row in scope.
  """
  def show_session(conn, %{"slug" => slug} = params) do
    dataset = params["dataset"] || Content.paper_default_dataset()

    case Content.get_blocks_doc(slug, "session", dataset) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "no session for slug #{slug}"}})

      doc ->
        json(
          conn,
          Map.merge(
            Map.take(doc.content || %{}, @session_keys ++ ["events"]),
            %{"slug" => slug, "rev" => doc.rev}
          )
        )
    end
  end

  @doc """
  Apply a single block op to a session's block list, via the GENERALIZED
  `Content.apply_document_block_op/5` (block_ops.ex — the pre-existing
  document-editor write path Task 2 reused rather than duplicating). Unlike
  the paper-only `apply_paper_block_op/3`, this returns NO `rev`/
  `fragment_html` in its `{:ok, %{block, block_id, op_kind, position}}`
  result — the receipt below reflects that shape exactly.
  """
  def apply_session_op(conn, %{"slug" => slug} = params) do
    op = Map.delete(params, "slug")

    cond do
      not valid_op_shape?(op) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "malformed_op", message: "op must name a known DocPatchOp"}})

      true ->
        dataset = params["dataset"] || Content.paper_default_dataset()

        case Content.apply_document_block_op(slug, "session", op, dataset) do
          {:ok, %{block_id: block_id, op_kind: op_kind, position: position}} ->
            conn
            |> put_status(:ok)
            |> json(%{ok: true, slug: slug, op: op_kind, block_id: block_id, position: position})

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "no session for slug #{slug}"}})

          {:error, {:constraint, message, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "constraint", message: message, op: op_kind}})

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

          {:error, {:halted, reason}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: %{code: "halted", message: reason}})

          {:error, _other} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "op could not be applied"}})
        end
    end
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

        dataset = params["dataset"] || Content.paper_default_dataset()

        case Content.apply_paper_block_ops(slug, ops, dataset, op_opts) do
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

          # Constraint-vocabulary veto (pdd-t20): the middle element IS the
          # human-readable violation, not a block id — surface it verbatim.
          {:error, {:constraint, message, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "constraint", message: message, op: op_kind}})

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

          # Server veto ({:halted, reason} — hollow-body ratchet once
          # p-hollow-gate-server lands at this seam) — surface the reason
          # VERBATIM with 409 rather than flattening it into the generic
          # invalid_op below.
          {:error, {:halted, reason}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: %{code: "halted", message: reason}})

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
        dataset = params["dataset"] || Content.paper_default_dataset()

        case Content.apply_paper_block_op(slug, op, dataset) do
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

          # Constraint-vocabulary veto (pdd-t20) — see the batch clause above.
          {:error, {:constraint, message, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "constraint", message: message, op: op_kind}})

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

          # Server veto ({:halted, reason}) — surface the reason VERBATIM
          # (see batch clause).
          {:error, {:halted, reason}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: %{code: "halted", message: reason}})

          {:error, _other} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_op", message: "op could not be applied"}})
        end
    end
  end

  @doc """
  The AI-proposes loop (lvw-t4). Apply INSERT-ONLY block ops to the paper's
  `drafts.<slug>` twin — seeded from the published row on first proposal —
  with mandatory provenance: a `proposal-source` content edge (draft → the
  `source.doc_id` document) plus a `content["proposals"]` sidecar that
  survives the publish copy. The published revision is NEVER written; approval
  flows through the existing draft→publish gate (no new state machine).

  Idempotent on block id: re-POSTing the same proposal skips already-present
  blocks (`skipped_block_ids`) and re-upserts the edge. Errors: 404 unknown
  slug; 422 for a mutating op kind, an id-less block, a malformed/unresolvable
  `source` (fail closed — NOTHING is written when provenance can't resolve).
  """
  def propose(conn, %{"slug" => slug} = params) do
    ops = params["ops"]
    source = params["source"]

    cond do
      not is_list(ops) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "malformed_proposal", message: "ops (a list of insert ops) is required"}
        })

      not is_map(source) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "missing_source",
            message: "source {doc_id, agent} is required — every proposal carries provenance"
          }
        })

      true ->
        dataset = params["dataset"] || Content.paper_default_dataset()

        case Content.propose_paper_blocks(slug, ops, source, dataset) do
          {:ok, receipt} ->
            conn
            |> put_status(:ok)
            |> json(%{
              ok: true,
              slug: receipt.slug,
              draft_id: receipt.draft_id,
              rev: receipt.rev,
              applied_block_ids: receipt.applied_block_ids,
              skipped_block_ids: receipt.skipped_block_ids,
              provenance: receipt.provenance,
              # The approval path — the EXISTING publish gate, spelled out so an
              # agent holding this receipt needs no second lookup.
              approve_via: %{
                mutate: %{publish: %{id: receipt.slug, type: "paper"}},
                endpoint: "/v1/data/mutate/#{dataset}"
              }
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "not_found", message: "no paper for slug #{slug}"}})

          {:error, :source_not_found} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "source_not_found",
                message:
                  "source.doc_id did not resolve to a document in scope; nothing was written"
              }
            })

          {:error, {:invalid_proposal, message}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "invalid_proposal", message: message}})

          # Constraint-vocabulary veto (pdd-t20) — see the batch clause above.
          {:error, {:constraint, message, op_kind}} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "constraint", message: message, op: op_kind}})

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

          {:error, _other} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{code: "invalid_proposal", message: "proposal could not be applied"}
            })
        end
    end
  end

  # Route a RAW publish-wall tuple through the shared v1 error envelope
  # (authoring-excellence D27) — mirrors FallbackController.call/2 so an ingest
  # rejection carries the same field/rule/fix details + code-keyed hint +
  # request_id an SDK already branches on. Zero new envelope code: the
  # label_spine / unknown_tag / duplicate_of builders + @hints entries live in
  # Barkpark.Content.Errors. NEVER used for the changeset path — a changeset
  # through to_envelope becomes validation_failed, breaking the public
  # invalid_paper contract — so that clause stays hand-rolled above.
  defp render_error(conn, tuple) do
    env = Errors.to_envelope(tuple, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  # Shared changeset catch-all for both ingest legs (blocks + html). code/message
  # stay the LOCKED external contract (invalid_paper / "could not store paper" —
  # see the render_error/2 comment above); `details` is ADDITIVE — the per-field
  # validation errors, so a caller can see exactly what failed instead of
  # guessing from the flat message.
  defp invalid_paper_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_paper",
        message: "could not store paper",
        details: changeset_field_errors(changeset)
      }
    })
  end

  defp changeset_field_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end

  # Fold any advisory-band warnings the publish wall queued during upsert_paper
  # into the SUCCESS body (authoring-excellence D36/D42) — mirrors
  # MutateController. Warnings.reset/0 opened the request-scoped queue before the
  # upsert; this drains it after. Without the reset+drain pair the wall's
  # advisories (a real signal — soft-dup near-misses, off-norm tag counts) were
  # silently dropped on every ingest (collect-only-when-listening, warnings.ex).
  # The `warnings` key is OMITTED when the drain is empty, so a compliant ingest
  # with no advisory keeps the byte-identical pre-wall body.
  defp with_warnings(body) do
    case Warnings.drain() do
      [] -> body
      warnings -> Map.put(body, :warnings, warnings)
    end
  end

  defp valid_ingest_text?(value) when is_binary(value) do
    String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp valid_ingest_text?(value) when is_list(value) do
    Enum.all?(value, &valid_ingest_text?/1)
  end

  defp valid_ingest_text?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} ->
      valid_ingest_text?(key) and valid_ingest_text?(nested_value)
    end)
  end

  defp valid_ingest_text?(_value), do: true

  defp invalid_text(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_text",
        message: "paper text must be valid UTF-8 and cannot contain NUL bytes"
      }
    })
  end

  # A minimally well-formed op: a map whose "op" is one of the five kinds.
  # Patch.apply_patch/2 does the deeper structural validation (required keys
  # per kind, id resolution); a shape failure there surfaces as a 422 above.
  defp valid_op_shape?(%{"op" => kind}) when kind in @op_kinds, do: true
  defp valid_op_shape?(_), do: false

  # W1.5-C: thread an OPTIONAL workspace/project into the upsert attrs so a
  # paper (and its emitted lifecycle event) lands in the goal's scope when
  # paper ingest starts sending it. The scope may arrive as either a JSON body
  # field (`workspace`/`project`, OR the explicit id `workspace_id`/`project_id`)
  # or an HTTP header (`x-barkpark-workspace` / `x-barkpark-project`, carrying a
  # slug). Slugs are resolved to ids via Tenancy; an unknown slug resolves to no
  # scope key → upsert_paper's Default fallback applies (never a hard error, so
  # the flat paper ingest keeps working unchanged). When NO scope is given,
  # the attrs are returned untouched and Default fallback handles it.
  defp put_scope(attrs, conn, params) do
    {ws_id, project_id} = resolve_scope(conn, params)

    attrs
    |> maybe_put("workspace_id", ws_id)
    |> maybe_put("project_id", project_id)
    # Dataset-aware ingest: an OPTIONAL "dataset" body param routes the upserted
    # paper doc + its blocks into that dataset. Absent → upsert_paper applies its
    # own default-dataset fallback (back-compat: existing producers unchanged).
    |> maybe_put("dataset", blank_to_nil(params["dataset"]))
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
  # The scoped reader path for the paper's OWN tenancy — nil when the scope
  # doesn't resolve to slugs (legacy NULL-scope rows). Additive next to the
  # contracted flat liveview_path.
  defp scoped_liveview_path(paper) do
    with ws_id when is_binary(ws_id) <- paper.workspace_id,
         %{slug: ws_slug} <- Barkpark.Tenancy.get_workspace_by_id(ws_id),
         proj_id when is_binary(proj_id) <- paper.project_id,
         %{slug: proj_slug} <- Barkpark.Tenancy.get_project_by_id(proj_id) do
      "/w/#{ws_slug}/p/#{proj_slug}/papers/#{paper.doc_id}"
    else
      _ -> nil
    end
  end
end
