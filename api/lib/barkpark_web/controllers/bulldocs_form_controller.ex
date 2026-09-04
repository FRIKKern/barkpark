defmodule BarkparkWeb.BulldocsFormController do
  @moduledoc """
  Anonymous submissions for a paper's `form` / `questionnaire` blocks — the
  submit wiring the render-only grill deliberately never had (study
  `/papers/portabledoc-potential-study`, play #5).

  `POST /v1/plugins/bulldocs/papers/:slug/form-responses` with
  `{"answers": {"<question-id>": "…" | ["…"]}}` stores ONE `form_response`
  document and returns `201 {"ok": true, "id": …}`.

  ## Trust model (anonymous, browser-reachable — every input is hostile)

    * **Paper-anchored**: the slug must resolve through `get_public_paper/1`
      (Default-workspace pinned, fail-closed), and the paper must actually
      carry a form block — you cannot post answers at a paper that never asked.
    * **Question-id allowlist**: submitted answer keys are filtered to the ids
      the paper's own form blocks declare; unknown keys are dropped, never
      stored. An answer set that filters to empty is a 422.
    * **Size caps**: ≤ #{50} answers; a string answer ≤ #{4000} bytes; a
      multi-choice answer ≤ #{50} items of ≤ #{500} bytes. Non-string junk in a
      list is dropped; a non-string/non-list answer drops the key.
    * **Abuse**: per-IP token bucket (`Barkpark.RateLimiter`, capacity 20,
      ~1/min refill) + a `website` honeypot field — bots that fill it get a
      vacuous 201 (no write) so the trap stays invisible.
    * **Privacy**: the `form_response` schema is `visibility: "private"` — the
      anonymous read API 404s responses; token/Studio reads see them.

  Responses stay in the DRAFT perspective (the tickets precedent): read them
  with `bp doc ls form_response --perspective drafts`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Papers

  @max_answers 50
  @max_string 4000
  @max_list 50
  @max_list_item 500
  @rate_capacity 20
  @rate_refill_per_sec 1 / 60

  def submit(conn, %{"slug" => slug} = params) do
    with :ok <- rate_limit(conn),
         :ok <- honeypot(params),
         {:ok, doc} <- fetch_paper(slug),
         {:ok, allowed} <- form_question_ids(doc),
         {:ok, answers} <- sanitize_answers(Map.get(params, "answers"), allowed),
         {:ok, stored} <- store(slug, doc, answers) do
      conn |> put_status(201) |> json(%{ok: true, id: stored.doc_id})
    else
      {:honeypot} ->
        # The trap stays invisible: same happy shape, nothing written.
        conn |> put_status(201) |> json(%{ok: true})

      {:error, :rate_limited} ->
        envelope(conn, 429, "rate_limited", "too many submissions from this address")

      {:error, :not_found} ->
        envelope(conn, 404, "not_found", "paper not found")

      {:error, :no_form} ->
        envelope(conn, 422, "validation_failed", "paper has no form block")

      {:error, :no_answers} ->
        envelope(conn, 422, "validation_failed", "no valid answers for this form's questions")

      {:error, _} ->
        envelope(conn, 422, "validation_failed", "invalid submission")
    end
  end

  # Error envelopes stay inside the ratified public vocabulary
  # (Content.Errors.known_codes/0 — the ErrorCodeCoverage contract): the code
  # is canonical, the MESSAGE carries the per-cause detail.
  defp envelope(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{
      ok: false,
      error: Barkpark.Content.Errors.stamp(%{code: code, message: message}, conn)
    })
  end

  # ── guards ─────────────────────────────────────────────────────────────────

  defp rate_limit(conn) do
    # `client_ip/1`, never `conn.remote_ip`: Caddy is co-located and dials
    # localhost:4000, so the peer is always 127.0.0.1 and this was ONE global
    # 20-submission budget for the entire internet — one abuser closed every
    # public form on the box. The resolver only believes `x-forwarded-for` from a
    # trusted front, so a direct caller cannot mint itself a fresh budget.
    ip = Barkpark.RateLimiter.client_ip(conn)

    key = {:bulldocs_form, ip}

    case Barkpark.RateLimiter.check(Barkpark.RateLimiter.scoped_key(conn, key),
           capacity: @rate_capacity,
           refill_per_sec: @rate_refill_per_sec
         ) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end

  defp honeypot(params) do
    case Map.get(params, "website") do
      v when is_binary(v) and v != "" -> {:honeypot}
      _ -> :ok
    end
  end

  defp fetch_paper(slug) do
    case Papers.get_public_paper(slug) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  # ── the question-id allowlist (walked from the paper's own blocks) ─────────

  defp form_question_ids(doc) do
    ids =
      (get_in(doc.content || %{}, ["blocks"]) || [])
      |> collect_form_ids(MapSet.new())

    if MapSet.size(ids) == 0, do: {:error, :no_form}, else: {:ok, ids}
  end

  defp collect_form_ids(blocks, acc) when is_list(blocks),
    do: Enum.reduce(blocks, acc, &collect_block/2)

  defp collect_form_ids(_other, acc), do: acc

  defp collect_block(%{"type" => t} = b, acc) when t in ["form", "questionnaire"] do
    b
    |> Map.get("questions", [])
    |> List.wrap()
    |> Enum.reduce(acc, fn
      %{"id" => id}, inner when is_binary(id) and id != "" -> MapSet.put(inner, id)
      _, inner -> inner
    end)
  end

  defp collect_block(%{} = b, acc) do
    # Containers nest under the same three shapes TaskResolver walks:
    # `children` / `blocks` (lists) and `columns` (a list of lists).
    acc
    |> collect_form_ids(Map.get(b, "children") || [], :list)
    |> collect_form_ids(Map.get(b, "blocks") || [], :list)
    |> collect_columns(Map.get(b, "columns"))
  end

  defp collect_block(_other, acc), do: acc

  defp collect_form_ids(acc, blocks, :list), do: collect_form_ids(blocks, acc)

  defp collect_columns(acc, columns) when is_list(columns),
    do: Enum.reduce(columns, acc, fn col, a -> collect_form_ids(col, a) end)

  defp collect_columns(acc, _), do: acc

  # ── answer sanitisation (allowlist ∩ caps; junk drops, never errors) ───────

  defp sanitize_answers(%{} = raw, allowed) do
    answers =
      raw
      |> Enum.filter(fn {k, _} -> is_binary(k) and MapSet.member?(allowed, k) end)
      |> Enum.take(@max_answers)
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        case sanitize_value(v) do
          nil -> acc
          clean -> Map.put(acc, k, clean)
        end
      end)

    if map_size(answers) == 0, do: {:error, :no_answers}, else: {:ok, answers}
  end

  defp sanitize_answers(_raw, _allowed), do: {:error, :no_answers}

  defp sanitize_value(v) when is_binary(v) do
    case String.slice(v, 0, @max_string) do
      "" -> nil
      s -> s
    end
  end

  defp sanitize_value(v) when is_list(v) do
    items =
      v
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@max_list)
      |> Enum.map(&String.slice(&1, 0, @max_list_item))
      |> Enum.reject(&(&1 == ""))

    if items == [], do: nil, else: items
  end

  defp sanitize_value(_), do: nil

  # ── storage ────────────────────────────────────────────────────────────────

  defp store(slug, doc, answers) do
    content = %{
      "paper_slug" => slug,
      "answers" => answers,
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Content.create_document(
      "form_response",
      %{"title" => "Form response — #{slug}", "content" => content},
      Papers.paper_default_dataset(),
      workspace_id: doc.workspace_id,
      project_id: doc.project_id
    )
  end
end
