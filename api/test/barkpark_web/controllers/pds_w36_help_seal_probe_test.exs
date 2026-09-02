defmodule BarkparkWeb.PdsW36HelpSealProbeTest do
  @moduledoc """
  PDS-D502 differential — the truncation-honesty `help[]` line must be computed
  from what the caller ACTUALLY RECEIVED.

  Before the repair, `task_list_response/3` (tasks_controller.ex:82-85) rendered
  the SEALED docs but handed `Params.maybe_put_brief_truncation_help/3` the RAW,
  UNSEALED list, and `GET /v1/tasks/prime` had the identical shape at :180. The
  help predicate reads `content["claim"]["now"]["text"]`, which `Params.seal/3`
  redacts for a non-admin when the tenant marks `claim` private — so the caller
  was told a field was truncated while nothing they received was truncated.

  The probes below are the permanent differential:

    * PROBE A (inverted) — the non-admin, claim-private caller now gets NO help
      line, because nothing they received lost bytes. Reverting the :83 hunk
      reds this test; that is the list route's mutation proof.
    * PROBE B — admin control: same corpus, claim visible, help[] fires honestly.
    * PROBE C — title control: `title` is a column, the seal only touches
      `content`, so a long title truncates honestly for a non-admin too.
    * PROBE D — the honest law as a BICONDITIONAL, with no `if` (the earlier
      `if body["help"] do assert … end` form went vacuous the moment the fix
      made `help` nil — its body simply stopped executing, which an `assert
      false` sentinel confirmed by still PASSING). It reds in BOTH directions
      and carries a MIXED-LIST case so it is not satisfied by corpus size.
      The two sides are bound to `help_present?` / `payload_truncated?` rather
      than written as `(a != nil) == b` only because the formatter restyles the
      parenthesised form; the assertion is the same biconditional.
    * PROBE E — the same law on `GET /v1/tasks/prime`; reverting the :180 hunk
      reds this test. It carries the MIXED case too, so prime's honest positive
      direction is pinned on prime's own route rather than borrowed from C/D.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "pds-w36-probe-admin"
  @nonadmin_token "pds-w36-probe-nonadmin"
  @dataset "production"

  # 200 graphemes > @brief_now_text_limit (160) / @brief_title_limit (96)
  @long_now String.duplicate("n", 200)
  @long_title String.duplicate("t", 200)

  setup do
    {:ok, _} = Auth.create_token(@token, "pds-w36-a", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@nonadmin_token, "pds-w36-n", "test", ["read", "write"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    # Mark `claim` PRIVATE on the task schema for this tenant.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "task",
          "title" => "Task",
          "fields" => [
            %{"name" => "claim", "private" => true},
            %{"name" => "public_field"}
          ]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp mk!(doc_id, title, scope, extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp long_claim(worker \\ "worker-1") do
    %{
      "worker" => worker,
      "epoch" => 1,
      "now" => %{"text" => @long_now, "ts" => "2026-08-01T00:00:00Z"}
    }
  end

  defp hdr(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp find_card(cards, id),
    do: Enum.find(cards, &(&1["doc_id"] == "drafts." <> id or &1["doc_id"] == id))

  test "PROBE A (inverted; MUTATION PROOF for the list route): a non-admin whose card carries NO claim gets NO help line",
       %{conn: conn, scope: scope} do
    id = uniq("probe-seal-help")

    _t = mk!(id, "short title", scope, %{"public_field" => "VISIBLE", "claim" => long_claim()})

    body =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks?view=brief&limit=1000")
      |> json_response(200)

    card = find_card(body["docs"], id)
    all_json = Jason.encode!(body["docs"])

    assert card, "probe task not in the brief list"
    refute Map.has_key?(card, "claim"), "claim NOT sealed away -- probe premise wrong"

    refute String.contains?(all_json, "…"),
           "some card carried a truncation marker -- the corpus premise is wrong"

    refute body["help"],
           "help[] claims a field was truncated, but NOTHING the caller received ends with … — docs=#{all_json}"
  end

  test "PROBE B: admin control -- same corpus, claim visible, help[] fires honestly",
       %{conn: conn, scope: scope} do
    id = uniq("probe-seal-admin")

    _t = mk!(id, "short title", scope, %{"claim" => long_claim()})

    body =
      conn
      |> hdr(@token)
      |> get("/v1/tasks?view=brief&limit=1000")
      |> json_response(200)

    card = find_card(body["docs"], id)

    assert card
    assert String.ends_with?(get_in(card, ["claim", "now", "text"]), "…")
    assert body["help"]
  end

  test "PROBE C: title truncation is NOT sealable (title is a column, seal only touches content)",
       %{conn: conn, scope: scope} do
    id = uniq("probe-title")
    _t = mk!(id, @long_title, scope, %{"public_field" => "VISIBLE"})

    body =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks?view=brief&limit=1000")
      |> json_response(200)

    card = find_card(body["docs"], id)

    assert card
    assert String.ends_with?(card["title"], "…")
    assert body["help"]
  end

  test "PROBE D (THE HONEST LAW, biconditional): help[] present <=> some card the caller received carries …",
       %{conn: conn, scope: scope} do
    # Case 1 — sealed-claim card ONLY: nothing the caller received is truncated.
    sealed_id = uniq("probe-law-sealed")
    _t = mk!(sealed_id, "short title", scope, %{"claim" => long_claim()})

    body =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks?view=brief&limit=1000")
      |> json_response(200)

    assert find_card(body["docs"], sealed_id), "sealed-claim card missing -- case 1 is vacuous"
    all_json = Jason.encode!(body["docs"])

    # The biconditional, spelled through two bindings so the formatter cannot
    # restyle the parenthesised form: help[] present <=> the payload truncated.
    help_present? = body["help"] != nil
    payload_truncated? = String.contains?(all_json, "…")

    assert help_present? == payload_truncated?,
           "help[]=#{inspect(body["help"])} disagrees with the payload — docs=#{all_json}"

    # Case 2 — MIXED LIST: the same sealed-claim card PLUS one genuinely
    # truncated card (long title). The biconditional must now hold the other
    # way round, so it cannot be satisfied by corpus size alone.
    long_id = uniq("probe-law-long")
    _t2 = mk!(long_id, @long_title, scope, %{"public_field" => "VISIBLE"})

    mixed =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks?view=brief&limit=1000")
      |> json_response(200)

    assert find_card(mixed["docs"], sealed_id), "mixed list lost the sealed-claim card"
    assert find_card(mixed["docs"], long_id), "mixed list lost the truncated card"
    mixed_json = Jason.encode!(mixed["docs"])
    mixed_help_present? = mixed["help"] != nil
    mixed_truncated? = String.contains?(mixed_json, "…")

    assert mixed_help_present? == mixed_truncated?,
           "help[]=#{inspect(mixed["help"])} disagrees with the payload — docs=#{mixed_json}"

    assert mixed["help"], "the mixed list DOES truncate a title — help[] must fire"
  end

  test "PROBE E (MUTATION PROOF for GET /v1/tasks/prime): the prime help[] line obeys the same biconditional",
       %{conn: conn, scope: scope} do
    id = uniq("probe-prime")

    # lifecycle_status "in_progress" — Tasks.Prime.in_progress/3 filters on it,
    # so without this the prime corpus is EMPTY and the probe is vacuous.
    _t =
      mk!(id, "short title", scope, %{
        "lifecycle_status" => "in_progress",
        "public_field" => "VISIBLE",
        "claim" => long_claim()
      })

    body =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks/prime?view=brief&limit=100")
      |> json_response(200)

    cards = (body["in_progress"] || []) ++ (body["ready"] || [])
    card = find_card(cards, id)
    all_json = Jason.encode!(cards)

    assert card, "prime corpus EMPTY of the probe task -- the probe would be vacuous"
    refute Map.has_key?(card, "claim"), "claim NOT sealed away -- probe premise wrong"

    help_present? = body["help"] != nil
    cards_truncated? = String.contains?(all_json, "…")

    assert help_present? == cards_truncated?,
           "prime help[]=#{inspect(body["help"])} disagrees with the cards it shipped — cards=#{all_json}"

    # Case 2 — MIXED prime corpus (wave-37 review): the same sealed-claim card
    # PLUS one genuinely truncated card (long title, also in_progress so it
    # reaches the prime lens). Without this, PROBE E only ever pinned the
    # negative direction on this route and prime's honest POSITIVE — help[]
    # firing when a card the caller received really is abridged — rode on the
    # list route's C/D. The biconditional now reds in both directions here too.
    long_id = uniq("probe-prime-long")

    _t2 =
      mk!(long_id, @long_title, scope, %{
        "lifecycle_status" => "in_progress",
        "public_field" => "VISIBLE"
      })

    mixed =
      conn
      |> hdr(@nonadmin_token)
      |> get("/v1/tasks/prime?view=brief&limit=100")
      |> json_response(200)

    mixed_cards = (mixed["in_progress"] || []) ++ (mixed["ready"] || [])
    mixed_json = Jason.encode!(mixed_cards)

    assert find_card(mixed_cards, id), "mixed prime corpus lost the sealed-claim card"
    assert find_card(mixed_cards, long_id), "mixed prime corpus lost the truncated card"

    mixed_help_present? = mixed["help"] != nil
    mixed_truncated? = String.contains?(mixed_json, "…")

    assert mixed_help_present? == mixed_truncated?,
           "prime help[]=#{inspect(mixed["help"])} disagrees with the cards it shipped — cards=#{mixed_json}"

    assert mixed["help"], "the mixed prime corpus DOES truncate a title — help[] must fire"
  end
end
