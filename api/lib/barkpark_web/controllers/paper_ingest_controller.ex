defmodule BarkparkWeb.PaperIngestController do
  @moduledoc """
  Ingest endpoint for paperflow papers (convergence MVP, masterplan Figure 6).

  Matches the request the `paperflow/hooks/event-on-save.sh` mirror block
  POSTs:

      POST /v1/paperflow/papers
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>   (RequireIngestToken plug)
      Content-Type: application/json
      {
        "source_doc": "plans/2026-05-23-foo.html",
        "slug":       "2026-05-23-foo",
        "event_type": "plan-written",
        "body_html":  "<article>…</article>",
        "goal_id":    "bd-a1b2"        // optional
      }

  Upserts the paper keyed by slug and broadcasts on its per-doc PubSub topic
  so any mounted `PaperLive` re-renders with no reload. Persists so a fresh
  mount renders the latest HTML.

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
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content

  # The five DocPatchOp discriminators (mirrors Barkpark.PortableDoc.Patch).
  @op_kinds ~w(append-block insert-after patch-block replace-block remove-block)

  def ingest(conn, %{"slug" => slug, "body_html" => body_html} = params)
      when is_binary(slug) and slug != "" and is_binary(body_html) do
    attrs = %{
      "slug" => slug,
      "body_html" => body_html,
      "source_doc" => params["source_doc"],
      "event_type" => params["event_type"],
      "goal_id" => params["goal_id"]
    }

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
    |> json(%{error: %{code: "malformed", message: "slug and body_html are required"}})
  end

  @doc """
  Apply a single DocPatchOp to the paper at `:slug`. The JSON body IS the op.

  Returns 200 with `{ok, slug, op, rev, block_id, fragment_html, position}` on
  success; 404 for an unknown slug; 422 for a malformed op or a patch failure
  (e.g. a block-not-found / type-mismatch on the target block list).
  """
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
end
