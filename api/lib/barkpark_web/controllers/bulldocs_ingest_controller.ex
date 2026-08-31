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
  alias Barkpark.PortableDoc.Bpml.UnprintableError
  alias Barkpark.Tenancy

  # The SIX DocPatchOp discriminators (mirrors Barkpark.PortableDoc.Patch).
  #
  # PDS-D458: `move-block` was absent here while `Patch.apply_to_blocks/2`
  # implemented it, `Patch`'s moduledoc documented it, `BlockOps
  # .locate_paper_affected/2` handled it and the Studio LiveView emitted it —
  # so over HTTP it 422'd `malformed_op` / "every op must name a known
  # DocPatchOp": an error saying a KNOWN verb is unknown. It is ADDED rather
  # than refused, because there was no rule keeping it out — only an
  # un-updated allowlist. (`Papers.Proposals`' `@insert_op_kinds` stays the
  # narrower `append-block`/`insert-after` pair: that one IS a real rule —
  # proposals may never touch an existing block — and it is not drift.)
  @op_kinds ~w(append-block insert-after patch-block replace-block remove-block move-block)

  # Learn-pointer advisory for the legacy body_html leg (authoring-excellence
  # ae-ingest-learn-pointer). The errors-as-instructions pattern teaches what
  # broke; this teaches WHERE THE STANDARDS LIVE at the point of use. A producer
  # who reaches for opaque body_html gets a NON-BLOCKING nudge toward the native
  # `blocks` grammar and the doctrine papers — advisory only, never a 4xx
  # (charter D5). Rides the existing Warnings channel opened by the wall wiring
  # (D36/D42): this is that pipe's FIRST content-shape consumer, not a duplicate.
  @body_html_learn_code "legacy_body_html"
  @body_html_learn_message "This paper was ingested as opaque body_html; the preferred path is a native `blocks` list (in-canvas editing, ~50 block types). Learn the block vocabulary and composition grammar in the doctrine papers /papers/portabledoc-doctrine and /papers/composition-doctrine-plan, then re-ingest with `blocks`."

  @doc """
  `POST /v1/plugins/bulldocs/papers/validate` — the validate-all dry-run (BPML
  masterplan W0). Accepts the SAME body shapes as ingest (`blocks` or `bpml`,
  plus `slug`/`title`/`tags`/`description`) and returns EVERY violation in one
  reply, nothing persisted:

    * BPML parse errors (strict grammar, teaching hints, line numbers) — when
      the document doesn't parse, wall gates can't run and the parse errors ARE
      the reply;
    * every failing publish-wall gate at once (`AuthoringWall.validate_all/5`:
      label spine, tag registry, dedup, epic quality) instead of one 4xx at a
      time;
    * the paper structural gates: template declarations and the hollow-body
      check.

  Always 200 with `{valid, violations}` — the VALIDATION ran successfully; the
  paper's shortcomings are data, not transport errors. Advisory by design: the
  real write's wall stays authoritative.
  """
  def validate(conn, params) do
    case validate_normalize(params) do
      {:error, bpml_errors} ->
        json(conn, %{valid: false, violations: Enum.map(bpml_errors, &bpml_violation/1)})

      {:ok, slug, blocks, merged} ->
        ref = %Barkpark.Content.Document{
          doc_id: slug,
          type: "paper",
          dataset: Content.paper_default_dataset(),
          title: merged["title"],
          content: %{
            "blocks" => blocks,
            "tags" => merged["tags"],
            "description" => merged["description"]
          }
        }

        violations = paper_wall_violations(conn, ref) ++ paper_structure_violations(blocks)
        json(conn, %{valid: violations == [], violations: violations})
    end
  end

  # The wall gates as ONE violation list — `AuthoringWall.validate_all/4` over a
  # synthesized in-memory ref, each tuple routed through the shared v1 envelope
  # (status dropped: these are data inside a reply, not the reply's transport).
  # SHARED by the validate dry-run and the create-on-push arm below so the two
  # doors cannot drift: what the dry-run reports IS what a create enforces.
  defp paper_wall_violations(conn, ref) do
    Barkpark.Content.AuthoringWall.validate_all(ref, "paper", ref.doc_id, ref.dataset)
    |> Enum.map(fn tuple ->
      {:error, tuple} |> Errors.to_envelope(conn) |> Map.delete(:status)
    end)
  end

  # The paper structural gates (template declarations + the hollow-body check)
  # as violation maps — the other shared half of the dry-run/create parity.
  defp paper_structure_violations(blocks) do
    structure =
      Barkpark.Content.Papers.Template.validate(blocks || []) ++
        if Barkpark.Content.Papers.Hollow.hollow?(blocks) do
          [
            %{
              code: "hollow_paper",
              message: "the paper is a skeleton — a title with no content blocks",
              hint: "add body blocks before publishing"
            }
          ]
        else
          []
        end

    Enum.map(structure, &structure_violation/1)
  end

  @doc """
  `POST /v1/plugins/bulldocs/papers/:slug/sync` — the working-copy push (BPML
  masterplan W3). The client sends its edited BPML document plus the rev its
  pull anchored on; the SERVER parses strictly, derives the op batch from an
  id-keyed diff (`Bpml.Diff.derive/2`, replay-proven before anything applies),
  and applies it atomically under `if_rev`. Nobody hand-writes an op, and the
  grammar keeps its single Elixir owner — the CLI never parses BPML.

    * parse failure → 422 with the collected teaching errors;
    * the slug does not exist → CREATE-ON-PUSH (pe-w6 / charter D41): the parsed
      document births the paper through the FULL publish wall — the same
      `AuthoringWall.validate_all` + `Template.validate` + `Hollow` gates the
      validate dry-run reports (shared helpers, so the doors cannot drift),
      then `Content.upsert_paper` (which re-runs the wall as the authority
      BEFORE any Repo write). A wall refusal is a 422 `create_wall` envelope
      carrying EVERY violation under `errors`, and writes NOTHING — no draft,
      no partial row. `baseRev` is not consulted on this arm (the scaffold
      anchors at rev 0; an EXISTING slug still 412s on a stale anchor). The
      document's own `<paper slug>` must match the pushed path slug (422
      `slug_mismatch` otherwise — the path is the identity);
    * the paper's CURRENT blocks are unprintable → 422 `bpml_unprintable`
      BEFORE any op derives (a BPML document cannot describe them, so a sync
      would silently delete every non-kernel block behind a 200);
    * applied but the post-write state is unprintable → still 200 with `rev`
      (the write LANDED — a 500 would strand the anchor) and `bpml: nil` plus a
      `bpml_unprintable` marker;
    * `baseRev` ≠ current rev → 412 (pull first — conflicts surface, nothing
      is silently lost);
    * no changes → 200 `{ok, unchanged: true}`;
    * applied → 200 `{ok, rev, op_count, bpml}` where `bpml` is the CANONICAL
      print of the persisted blocks (post-normalization) — the client
      overwrites its file with it, so working copies always converge on the
      server's truth.
  """
  def sync(conn, %{"slug" => slug} = params) do
    bpml = params["bpml"]
    base_rev = params["baseRev"]
    dataset = params["dataset"] || Content.paper_default_dataset()
    scope = paper_scope_opts(conn, params)

    cond do
      not is_binary(bpml) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "malformed", message: "sync needs a bpml (string) body"}})

      not (is_binary(base_rev) and base_rev != "") ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            code: "malformed",
            message: "sync needs baseRev — the rev your pull anchored on (x-paper-rev)"
          }
        })

      true ->
        case Barkpark.PortableDoc.Bpml.parse_paper(bpml) do
          {:error, errors} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{code: "bpml", message: "the BPML document did not parse", errors: errors}
            })

          {:ok, parsed} ->
            sync_apply(conn, slug, parsed, base_rev, dataset, scope)
        end
    end
  end

  defp sync_apply(conn, slug, parsed, base_rev, dataset, scope) do
    case Content.get_paper(slug, dataset, scope) do
      nil ->
        sync_create(conn, slug, parsed, dataset, scope)

      paper ->
        # The paper-level integer rev — the same value the ops if_rev guard
        # compares (content["rev"]), and the same one pull anchors in
        # x-paper-rev. NEVER the row's _rev hash.
        current_rev = to_string(get_in(paper.content || %{}, ["rev"]))
        current_blocks = get_in(paper.content || %{}, ["blocks"]) || []
        unprintable = unprintable_current(current_blocks)

        cond do
          # ENTRY GUARD, before anything derives. If the paper's CURRENT blocks
          # cannot be printed as BPML, the pushed document cannot describe them
          # either — and `Diff.derive/2` would faithfully remove every block the
          # (necessarily kernel-only) parse does not carry: a silent DESTRUCTION
          # behind a 200. Nothing legitimate breaks, because pull already
          # refuses such a paper (422) — no client can hold a working copy of
          # one. Ordered before the rev check on purpose: an unprintable paper
          # has no honest BPML sync at ANY rev, so "pull first" would be a lie.
          unprintable != nil ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "bpml_unprintable",
                message:
                  "this paper's current blocks cannot be printed as BPML, so a BPML document cannot describe them — syncing would delete everything outside the kernel: #{unprintable}",
                hint:
                  "edit this paper with block ops (or bp bulldocs publish); BPML sync works once every block is inside the kernel vocabulary"
              }
            })

          current_rev != to_string(base_rev) ->
            conn
            |> put_status(:precondition_failed)
            |> json(%{
              error: %{
                code: "precondition_failed",
                message: "paper is at rev #{current_rev}, your copy anchored on #{base_rev}",
                hint: "bp paper pull to absorb the drift, re-apply your edit, push again"
              }
            })

          true ->
            case Barkpark.PortableDoc.Bpml.Diff.derive(current_blocks, parsed["blocks"] || []) do
              {:error, :diff_verification_failed} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{
                  error: %{
                    code: "bpml",
                    message: "the derived op batch failed its replay proof — nothing was applied",
                    hint: "this is a server-side differ bug; fall back to bp bulldocs publish"
                  }
                })

              {:ok, _minted, []} ->
                conn
                |> put_resp_header("x-paper-rev", current_rev)
                |> json(%{ok: true, slug: slug, unchanged: true, rev: current_rev, op_count: 0})

              {:ok, _minted, ops} ->
                sync_persist(conn, slug, ops, base_rev, dataset, scope)
            end
        end
    end
  end

  defp sync_persist(conn, slug, ops, base_rev, dataset, scope) do
    case Content.apply_paper_block_ops(slug, ops, dataset, scope ++ [if_rev: base_rev]) do
      {:ok, result} ->
        {canonical, echo_refusal} =
          case Content.get_paper(slug, dataset, scope) do
            nil -> {nil, nil}
            paper -> canonical_echo(paper)
          end

        payload = %{
          ok: true,
          slug: result.slug,
          # STRING on the wire, like x-paper-rev and the unchanged leg — one
          # rev spelling for the working copy to anchor on.
          rev: to_string(result.rev),
          op_count: result.op_count,
          bpml: canonical
        }

        conn
        |> put_resp_header("x-paper-rev", to_string(result.rev))
        |> json(maybe_mark_echo(payload, echo_refusal))

      {:error, :precondition_failed} ->
        conn
        |> put_status(:precondition_failed)
        |> json(%{
          error: %{
            code: "precondition_failed",
            message: "another write landed mid-sync; no ops applied",
            hint: "bp paper pull, re-apply your edit, push again"
          }
        })

      {:error, {:constraint, message, op_kind}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "constraint", message: message, op: op_kind}})

      {:error, {:halted, reason}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "halted", message: reason}})

      {:error, _other} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "invalid_op", message: "the derived batch could not be applied"}
        })
    end
  end

  # Create-on-push (pe-w6 / charter D41): the sync door's birth arm. An absent
  # slug + a parsed document = the paper does not exist yet, so CREATE it —
  # through the FULL publish wall, never around it, and never via the
  # RequireIngestToken ingest route (this stays the sync route the working
  # copy already authenticated on).
  #
  # Wall order, deliberately validate-first: the SAME shared helpers the
  # validate dry-run uses (`paper_wall_violations/2` + `paper_structure_
  # violations/1`) run over the parsed document and, on ANY violation, refuse
  # with every violation in ONE 422 — before `upsert_paper` is even called, so
  # a wall-refused create provably writes NOTHING. The upsert then re-runs the
  # wall as the AUTHORITY (enforce_blocks_wall sits before the Repo insert in
  # BlockOps — its own refusals also precede any write); its residual errors
  # (a dedup race, a changeset) route through the same envelopes as ingest.
  #
  # NOTE the deliberate absence of a locked title stamp: BPML cannot spell
  # `role`/`locked`, and `Diff.derive/2` compares blocks by FULL map equality —
  # a locked-title paper's every future push would derive a replace-block that
  # strips `locked`, which `Patch.check_locked_placement/3` rejects. The one
  # door must birth papers the same door can keep editing, so the created
  # paper keeps its plain h1 (whose text still becomes the row title via
  # `BlockOps.paper_title/2`), and `Template.validate/1` passes it under the
  # additive no-locked-blocks rule — exactly as the validate dry-run does.
  defp sync_create(conn, slug, parsed, dataset, scope) do
    doc_slug = parsed["slug"]

    if is_binary(doc_slug) and doc_slug != "" and doc_slug != slug do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        error: %{
          code: "slug_mismatch",
          message:
            "the document says <paper slug=\"#{doc_slug}\"> but you pushed to #{slug} — nothing was written",
          hint:
            "the pushed path is the paper's identity; rename the file or fix the <paper slug> so they agree"
        }
      })
    else
      blocks = parsed["blocks"] || []

      ref = %Barkpark.Content.Document{
        doc_id: slug,
        type: "paper",
        dataset: dataset,
        title: create_title(blocks, parsed, slug),
        content: %{
          "blocks" => blocks,
          "tags" => parsed["tags"],
          "description" => parsed["description"]
        }
      }

      case paper_wall_violations(conn, ref) ++ paper_structure_violations(blocks) do
        [] ->
          sync_create_persist(conn, slug, parsed, blocks, dataset, scope)

        violations ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: %{
              code: "create_wall",
              message:
                "no paper #{slug} exists yet; creating it ran the full publish wall, which refused — nothing was written",
              hint:
                "fix each violation below; see them before pushing with the dry-run: bp paper push #{slug} --check (POST /v1/plugins/bulldocs/papers/validate)",
              errors: violations
            }
          })
      end
    end
  end

  defp sync_create_persist(conn, slug, parsed, blocks, dataset, scope) do
    attrs =
      %{
        "slug" => slug,
        "blocks" => blocks,
        "style" => parsed["style"] || "article",
        "tags" => parsed["tags"],
        "description" => parsed["description"],
        "dataset" => dataset
      }
      |> maybe_put("workspace_id", scope[:workspace_id])
      |> maybe_put("project_id", scope[:project_id])

    # Advisory channel — same reset+drain pair as the ingest legs (D36/D42),
    # so the wall's advise band (soft-dup near-miss, off-norm tag count) rides
    # the created receipt instead of being silently dropped.
    Warnings.reset()

    case Content.upsert_paper(attrs) do
      {:ok, paper} ->
        {canonical, echo_refusal} = canonical_echo(paper)
        rev = to_string(get_in(paper.content || %{}, ["rev"]))

        payload = %{
          ok: true,
          slug: paper.doc_id,
          created: true,
          rev: rev,
          op_count: length(get_in(paper.content || %{}, ["blocks"]) || []),
          bpml: canonical
        }

        conn
        |> put_resp_header("x-paper-rev", rev)
        |> json(maybe_mark_echo(with_warnings(payload), echo_refusal))

      # The residual refusals AFTER the validate-first precheck (a dedup race,
      # an encryption seal failure, a changeset) — routed exactly like the
      # ingest legs so every wall shape keeps its one envelope. None of these
      # arms follow a write: enforce_blocks_wall precedes the Repo insert.
      {:error, {:halted, reason}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "halted", message: reason}})

      {:error, {:label_spine, _}} = err ->
        render_error(conn, err)

      {:error, {:invalid_paper_structure, _}} = err ->
        render_error(conn, err)

      {:error, {:unknown_tag, _}} = err ->
        render_error(conn, err)

      {:error, {:duplicate_of, _}} = err ->
        render_error(conn, err)

      {:error, {:invalid_epic_paper_quality, _}} = err ->
        render_error(conn, err)

      {:error, {:dedup_unavailable, reason}} ->
        dedup_unavailable_error(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        invalid_paper_error(conn, changeset)

      {:error, _reason} = err ->
        render_error(conn, err)
    end
  end

  # The create precheck's title, derived the way the upsert wall will derive it
  # (`BlockOps.paper_title/2`: first heading's text wins) so the dry-run-shaped
  # precheck walls the SAME title the authoritative wall sees.
  defp create_title(blocks, parsed, slug) do
    heading_text =
      Enum.find_value(blocks, fn b ->
        if is_map(b) and b["type"] == "heading" and is_binary(b["text"]) and b["text"] != "",
          do: b["text"]
      end)

    heading_text || parsed["title"] || slug
  end

  # The sync entry guard's probe: nil when every current block is printable,
  # else the printer's typed refusal message (kind+type). A print is pure string
  # work on blocks already in memory — cheap enough to run before deriving.
  defp unprintable_current(blocks) do
    _ = Barkpark.PortableDoc.Bpml.print_blocks(blocks)
    nil
  rescue
    e in UnprintableError -> Exception.message(e)
  end

  # The canonical echo AFTER a successful write. The ops already committed, so an
  # unprintable post-write state must NOT change the verdict: a 500 would strand
  # the client's rev anchor on a write that landed, and a 422 would simply lie.
  # It degrades to `bpml: nil` plus an explicit marker, and the rev is still the
  # anchor to pull from. Only UnprintableError is rescued — a real printer bug
  # still crashes loudly (charter D3).
  # Public (not an action — no route names it) so the degrade contract is
  # directly testable: the sync path itself can no longer REACH an unprintable
  # post-write state now that the entry guard closes that door, and a rescue
  # nobody can prove is a rescue nobody should trust.
  @doc false
  def canonical_echo(paper) do
    blocks = get_in(paper.content || %{}, ["blocks"]) || []

    bpml =
      Barkpark.PortableDoc.Bpml.print_paper(Barkpark.Content.Papers.bpml_paper_map(paper, blocks))

    {bpml, nil}
  rescue
    e in UnprintableError -> {nil, Exception.message(e)}
  end

  @doc false
  def maybe_mark_echo(payload, nil), do: payload

  def maybe_mark_echo(payload, refusal) do
    Map.merge(payload, %{
      bpml_unprintable: refusal,
      hint:
        "the ops applied and `rev` is your new anchor, but the persisted blocks can no longer be printed as BPML — pull format=json to see them"
    })
  end

  # Normalize the two accepted validate bodies down to {slug, blocks, merged}.
  defp validate_normalize(%{"bpml" => bpml}) when is_binary(bpml) do
    case Barkpark.PortableDoc.Bpml.parse_paper(bpml) do
      {:ok, parsed} -> {:ok, parsed["slug"] || "unvalidated-paper", parsed["blocks"], parsed}
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_normalize(%{} = params) do
    {:ok, params["slug"] || "unvalidated-paper", params["blocks"], params}
  end

  defp bpml_violation(e),
    do: %{code: "bpml-" <> e.code, message: e.message, line: e.line, hint: e.hint}

  defp structure_violation(%{code: _} = v), do: v
  defp structure_violation(other) when is_binary(other), do: %{code: "structure", message: other}
  defp structure_violation(other), do: %{code: "structure", message: inspect(other)}

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

      # BPML leg (masterplan W1): the body carries a whole <paper> document as
      # readable markup. Parse (strict, teaching errors) → the parsed doc's
      # slug/title/description/tags/blocks feed the SAME blocks path as native
      # JSON — BPML is a spelling, never a second pipeline. Explicit top-level
      # params win over the parsed document's fields.
      %{"bpml" => bpml} = accepted when is_binary(bpml) ->
        case Barkpark.PortableDoc.Bpml.parse_paper(bpml) do
          {:ok, parsed} ->
            merged =
              parsed
              |> Map.delete("blocks")
              |> Map.merge(Map.delete(accepted, "bpml"))

            slug = merged["slug"]

            cond do
              not (is_binary(slug) and slug != "") ->
                conn
                |> put_status(:bad_request)
                |> json(%{
                  error: %{
                    code: "malformed",
                    message: "no slug: pass it on <paper slug=\"…\"> or as a top-level param"
                  }
                })

              not valid_ingest_text?(Map.put(merged, "blocks", parsed["blocks"])) ->
                invalid_text(conn)

              true ->
                ingest_blocks(conn, slug, parsed["blocks"], merged)
            end

          {:error, errors} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "bpml",
                message: "the BPML document did not parse",
                errors: errors
              }
            })
        end

      _malformed ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            code: "malformed",
            message:
              "slug plus either blocks (list), body_html (string), or bpml (string) are required"
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
        "description" => params["description"],
        # Explicit authoring-wall trail for deliberate editorial series (for
        # example one Chronicle chapter per calendar month). The wall owns the
        # semantics; ingest must not silently discard the caller's auditable
        # bypass decision before Content.upsert_paper/1 evaluates it.
        "dedup_bypass" => params["dedup_bypass"]
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

      {:error, {:invalid_paper_structure, _}} = err ->
        render_error(conn, err)

      {:error, {:unknown_tag, _}} = err ->
        render_error(conn, err)

      {:error, {:duplicate_of, _}} = err ->
        render_error(conn, err)

      # The wall's FIFTH shape (deploy-reliability D541). Hand-routing only the
      # four above meant this tuple fell into the changeset catch-all below, and
      # a bare variable matches a tuple: invalid_paper_error/2 handed the WALL
      # TUPLE to Ecto.Changeset.traverse_errors/2 (one clause, `%Changeset{}`) →
      # FunctionClauseError → 500 "unknown error", while the wall had already
      # computed the named failures. 33 of 299 distinct trailing-24h 500s on
      # guerrilla's live slot were this, including the epic cycle's own
      # wave-Paper publish. The 422 envelope already exists (errors.ex).
      {:error, {:invalid_epic_paper_quality, _}} = err ->
        render_error(conn, err)

      # The wall's SIXTH shape, and the only TRANSIENT one: the duplicate scan
      # could not RUN (pool saturation / blown query budget). Its own arm, NOT
      # render_error/2 — the shared envelope stamps the plugin-veto hint
      # ("A plugin's lifecycle hook vetoed this write"), which describes an
      # outage as a policy refusal and sends the caller to fix a document that
      # is fine (charter D542). The wire code/status stay `halted` 409 (what
      # errors.ex already emits and docs/api-v1.md §9 documents); the honest
      # 503 `dedup_unavailable` is the separately-filed contract change
      # (dr-w32-bl-dedup-unavailable-is-an-outage-called-a-veto) so a wall fix
      # and a vocabulary change do not ride one PR.
      {:error, {:dedup_unavailable, reason}} ->
        dedup_unavailable_error(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        invalid_paper_error(conn, changeset)

      # Any OTHER non-changeset reason goes through the shared envelope rather
      # than the changeset renderer. The 500 this head cured WAS a non-changeset
      # reason reaching a changeset-only renderer; a bare tail would rebuild it
      # for the next shape the wall learns.
      {:error, _reason} = err ->
        render_error(conn, err)
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
        "description" => params["description"],
        "dedup_bypass" => params["dedup_bypass"]
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

      # Wall shapes five and six — see the blocks head above (D541/D542). This
      # leg is walled identically, so it 500'd identically.
      {:error, {:invalid_epic_paper_quality, _}} = err ->
        render_error(conn, err)

      {:error, {:dedup_unavailable, reason}} ->
        dedup_unavailable_error(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        invalid_paper_error(conn, changeset)

      {:error, _reason} = err ->
        render_error(conn, err)
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

      # Shape-parity with the paper legs (D541/D542) — dead code for "session"
      # today (`@walled_types` is `~w(paper task)`), live the day a walled
      # blocks-type joins the whitelist, which is exactly when a bare catch-all
      # would 500 again.
      {:error, {:invalid_epic_paper_quality, _}} = err ->
        render_error(conn, err)

      {:error, {:dedup_unavailable, reason}} ->
        dedup_unavailable_error(conn, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        invalid_paper_error(conn, changeset)

      {:error, _reason} = err ->
        render_error(conn, err)
    end
  end

  def ingest_session(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "missing_slug", message: "slug required"}})
  end

  @doc """
  Read a session by slug — the same visibility tier as the writes
  (`auth: :ingest`). This is the ONLY session reader: there is no public
  session route (`/papers/:slug` resolves `type: "paper"` only) and the query
  API refuses `type=session` to an anonymous caller because session.json is
  `visibility: "private"` (sessions carry cwd/hostname/git state). 404 when
  the slug doesn't resolve to a "session" row in scope.

  Scoped by the SAME workspace/project resolution `ingest_session/2` threads
  via `put_scope/3` (`resolve_scope/2` below) — two workspaces can each hold
  their own row at the SAME slug (`upsert_blocks_doc/3` disambiguates writes
  by scope), so an unscoped read here would either return the wrong tenant's
  session or blow up `Repo.one()` with `Ecto.MultipleResultsError` once more
  than one workspace has written the slug.
  """
  def show_session(conn, %{"slug" => slug} = params) do
    dataset = params["dataset"] || Content.paper_default_dataset()

    case Content.get_blocks_doc(slug, "session", dataset, session_scope_opts(conn, params)) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "no session for slug #{slug}"}})

      doc ->
        json(
          conn,
          Map.merge(
            Map.take(doc.content || %{}, @session_keys ++ ["events", "conversations"]),
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

  DRAFT SEMANTICS (session-handoff final review, F5). The generic block-op path
  writes its patched content to the `drafts.<slug>` TWIN, never to the
  published `<slug>` row that `show_session/2` (and `bp session view`) reads.
  So an op applied here is INVISIBLE to every session reader until a
  `POST /v1/plugins/bulldocs/sessions` upsert republishes the slug. That is
  not hidden: the receipt names the row it actually wrote (`written_doc_id`)
  and carries a `note` saying so. Publish-through (ops landing straight on the
  published row) is deliberately DEFERRED — `bp session publish` is the
  supported way to change a session's blocks, and it is what the session skill
  uses.
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

        case Content.apply_document_block_op(
               slug,
               "session",
               op,
               dataset,
               session_scope_opts(conn, params)
             ) do
          {:ok,
           %{
             block_id: block_id,
             op_kind: op_kind,
             position: position,
             written_doc_id: written_doc_id
           }} ->
            conn
            |> put_status(:ok)
            |> json(%{
              ok: true,
              slug: slug,
              op: op_kind,
              block_id: block_id,
              position: position,
              # F5: name the row that was ACTUALLY written (the draft twin) and
              # say plainly that it is not yet the row a reader sees.
              written_doc_id: written_doc_id,
              note: "ops write the draft twin; publish to make visible"
            })

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
  Append one server-stamped event to a session's trail (session-handoff
  Task 4), via `Barkpark.Content.Sessions.append_event/5`. `params` may carry
  `"ref"` and/or `"note"`; `ts` is always server-minted. Scoped by the SAME
  `session_scope_opts/2` the read/op actions above thread, so two workspaces
  holding their own row at the same slug each append to their OWN trail.
  """
  def append_session_event(conn, %{"slug" => slug} = params) do
    dataset = params["dataset"] || Content.paper_default_dataset()

    case Barkpark.Content.Sessions.append_event(
           slug,
           params["kind"],
           params,
           dataset,
           session_scope_opts(conn, params)
         ) do
      {:ok, %{count: count}} ->
        conn
        |> put_status(:ok)
        |> json(%{ok: true, slug: slug, count: count})

      {:error, :invalid_kind} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "invalid_kind",
            message: "kind must be one of the allowed session event kinds",
            allowed: Barkpark.Content.Sessions.event_kinds()
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "no session for slug #{slug}"}})

      {:error, :stale} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{code: "conflict_retry", message: "session was updated concurrently; retry"}
        })
    end
  end

  @doc """
  Register or refresh a harness conversation on a session's registry
  (session-conversations slice), via
  `Barkpark.Content.Sessions.touch_conversation/5`. `params["conversation"]`
  is the conversation id; the rest of `params` is passed through as attrs and
  whitelisted inside the context (`harness`/`account`/`machine`/`cwd`) — the
  server always stamps `first_seen`/`last_active`, never the caller. Scoped by
  the SAME `session_scope_opts/2` the other session actions thread.
  """
  def touch_session_conversation(conn, %{"slug" => slug} = params) do
    dataset = params["dataset"] || Content.paper_default_dataset()

    case Barkpark.Content.Sessions.touch_conversation(
           slug,
           params["conversation"],
           params,
           dataset,
           session_scope_opts(conn, params)
         ) do
      {:ok, %{count: count}} ->
        conn
        |> put_status(:ok)
        |> json(%{ok: true, slug: slug, count: count})

      {:error, :invalid_conversation} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "invalid_conversation",
            message: "conversation id must be a non-empty string"
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "no session for slug #{slug}"}})

      {:error, :stale} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{code: "conflict_retry", message: "session was updated concurrently; retry"}
        })
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
    case expand_bpml_ops(ops) do
      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "bpml", message: "a BPML op fragment did not parse", errors: errors}
        })

      {:ok, ops} ->
        apply_op_batch(conn, slug, ops, params)
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

        case Content.apply_paper_block_op(
               slug,
               op,
               dataset,
               paper_scope_opts(conn, params)
             ) do
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

  defp apply_op_batch(conn, slug, ops, params) do
    cond do
      not Enum.all?(ops, &valid_op_shape?/1) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "malformed_op", message: "every op must name a known DocPatchOp"}
        })

      true ->
        op_opts =
          paper_scope_opts(conn, params) ++
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

  # An op MAY spell its payload as BPML: {"op":"replace-block","id":…,"bpml":"<callout …>"}.
  # The fragment must parse to EXACTLY one block — one op, one block, so op
  # receipts and counts stay truthful; multi-block edits are multiple ops.
  defp expand_bpml_ops(ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"bpml" => bpml} = op, idx}, {:ok, acc} when is_binary(bpml) ->
        case Barkpark.PortableDoc.Bpml.parse_blocks(bpml) do
          {:ok, [block]} ->
            {:cont, {:ok, [op |> Map.delete("bpml") |> Map.put("block", block) | acc]}}

          {:ok, blocks} ->
            {:halt,
             {:error,
              [
                %{
                  code: "bpml-fragment-arity",
                  message:
                    "op #{idx} bpml fragment parsed to #{length(blocks)} blocks — an op carries exactly one",
                  line: 1,
                  hint: "split into one op per block"
                }
              ]}}

          {:error, errors} ->
            {:halt, {:error, Enum.map(errors, &Map.put(&1, :op_index, idx))}}
        end

      {op, _idx}, {:ok, acc} ->
        {:cont, {:ok, [op | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # W1.5-C / session-handoff parity: Paper block ops, like reads and session
  # ops, must resolve the row in the request's workspace/project. Without this
  # option threading, two tenants sharing a slug can patch whichever Default
  # row the server happens to resolve.
  defp paper_scope_opts(conn, params), do: session_scope_opts(conn, params)

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
  # The %Ecto.Changeset{} pattern is LOAD-BEARING, not decoration: this head is
  # changeset-only (traverse_errors/2 has exactly one clause and matches
  # `%Changeset{}`), and the untyped head it replaces silently accepted the wall
  # tuples the case clauses above forgot, turning a computed 422 into a 500
  # "unknown error" (deploy-reliability D541). A future unrouted shape now fails
  # at the case, visibly, instead of inside Ecto.
  defp invalid_paper_error(conn, %Ecto.Changeset{} = changeset) do
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

  # The dedup wall could not RUN. Nothing was written and nothing was refused on
  # the merits — so the caller's correct move is to RESEND THE SAME REQUEST, not
  # to edit the paper. It is BUILT by the shared envelope (so code, message,
  # status and — the part a hand-rolled body silently dropped — `request_id` stay
  # byte-identical to what every other v1 error carries, and an operator can
  # actually quote the failing request) and then has exactly ONE field replaced:
  # the code-keyed `halted` hint, which reads "A plugin's lifecycle hook vetoed
  # this write" and is the one sentence that would send an author editing a
  # document that is fine (charter D542). The wire code/status stay `halted` 409
  # (docs/api-v1.md §9) — the honest 503 `dedup_unavailable` code is a
  # vocabulary change filed on its own task, because registering a new code
  # forces an errors.ex + byte-capped docs edit.
  @dedup_unavailable_hint "Transient: the duplicate-scan could not complete, so this paper was neither written nor refused on its merits. Resend the identical request. If it keeps failing the database is degraded — this is an outage to report, not a document to fix."

  defp dedup_unavailable_error(conn, reason) do
    env = Errors.to_envelope({:error, {:dedup_unavailable, reason}}, conn)

    body =
      env
      |> Map.delete(:status)
      |> Map.put(:hint, @dedup_unavailable_hint)

    conn
    # `retry-after` makes the transience machine-readable. 5s is a floor, not a
    # measurement — nothing yet measures how long a saturated pool takes to
    # recover, and a caller that retries later is never worse off.
    |> put_resp_header("retry-after", "5")
    |> put_status(env.status)
    |> json(%{error: body})
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

  # Read-side twin of `put_scope/3`: the SAME `resolve_scope/2` resolution
  # (explicit `workspace_id`/`project_id`, else a `workspace`/`project` slug
  # from the body or the `x-barkpark-workspace`/`x-barkpark-project` header),
  # reshaped into the `Content.get_blocks_doc/4` / `apply_document_block_op/5`
  # opts keyword list. `{nil, nil}` (no scope given at all) yields `[]`, which
  # `Content.Scope.scope_to_workspace_or_global/3` treats as an EXPLICIT
  # global read — matching the write side's own Default-workspace fallback
  # posture (a scope-less write still stamps a real workspace_id; a
  # scope-less read here just doesn't narrow by one).
  defp session_scope_opts(conn, params) do
    case resolve_scope(conn, params) do
      {nil, nil} -> []
      {ws_id, project_id} -> [workspace_id: ws_id, project_id: project_id]
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
