defmodule Barkpark.Tasks.Board.ClaimForwardLiveProbeTest do
  @moduledoc """
  The claim-forward predicate run against a LIVE instance's derived-ready
  overlay — `GET /v1/tasks/prime` — instead of a fixture.

  ## Why this file exists

  Readiness is DERIVED, never stored (the stored enum is
  `open|in_progress|blocked|done|cancelled`). It is derived by two routes: the
  SERVER route (`Tasks.Queue.ready/1`, which prime's ready head serves) and the
  BOARD route (`Board.build/2`'s in-memory overlay, which the Studio ready column
  renders). A board that agrees with every fixture can still disagree with the
  live queue, so this probe hands the BOARD route the LIVE server route's answer
  and asks `ClaimForward.violations/2` whether they part company.

  ## What it proves, and what it deliberately does NOT

  PROVES, on the live corpus: the live ready head and the live in-flight set are
  disjoint; every document the live queue calls ready buckets to `:ready` under
  the board's own `Board.build/2` (so the two claimability ladders have not
  forked — a live row carrying a lifecycle value no fixture uses would red here);
  and the claim-forward clauses C0/C1/C2 hold over that pairing.

  DOES NOT PROVE: that the RENDERED Studio board in a browser on that host paints
  that column. Observing the rendered GUI on a deployed host is a live browser
  walk, which is OWNER-GATED under the round brief. This probe is the
  server-side half that needs no owner; the browser half is handed to the owner
  rather than substituted with a fixture (task-adaae4196cffa86f, criterion 3).

  ## Running it

      BARKPARK_LIVE_URL=https://guerrilla.barkpark.cloud \\
      BARKPARK_LIVE_TOKEN=<a read token> \\
      mix test --include live_probe \\
        test/barkpark/tasks/board/claim_forward_live_probe_test.exs

  Excluded by default (`:live_probe` in test_helper.exs) — it needs a network
  and a credential. Mirrors the TUI half's `-tags liveprobe`.
  """

  use ExUnit.Case, async: false

  @moduletag :live_probe

  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Board.ClaimForward

  @limit 100

  test "the live derived-ready head satisfies the claim-forward contract" do
    url = System.get_env("BARKPARK_LIVE_URL")
    token = System.get_env("BARKPARK_LIVE_TOKEN")

    if is_nil(url) or is_nil(token) do
      flunk("""
      BARKPARK_LIVE_URL and BARKPARK_LIVE_TOKEN must both be set — this probe
      reads a REAL instance's /v1/tasks/prime. A probe that silently passes with
      no host is exactly the vacuous green it exists to prevent.
      """)
    end

    prime = fetch_prime!(url, token)

    ready_docs = Map.get(prime, "ready", [])
    in_progress_docs = Map.get(prime, "in_progress", [])
    counts = Map.get(prime, "counts", %{})

    ready_ids = Enum.map(ready_docs, &doc_id/1)
    in_progress_ids = Enum.map(in_progress_docs, &doc_id/1)
    overlay = %{ready_ids: ready_ids, in_progress_ids: in_progress_ids}

    # The board route, over the LIVE documents: the same `Board.build/2` the
    # Studio column renders through.
    board = Board.build(Enum.map(ready_docs ++ in_progress_docs, &to_card/1))
    surfaced = ClaimForward.surfaced_ready_ids(board)
    violations = ClaimForward.violations(board, overlay)

    IO.puts("""

    ── claim-forward LIVE probe ────────────────────────────────────────────────
    host                : #{url}
    fetched_at          : #{DateTime.utc_now() |> DateTime.to_iso8601()}
    corpus counts       : #{inspect(counts)}
    overlay ready head  : #{length(ready_ids)} (limit #{@limit})
    overlay in-flight   : #{length(in_progress_ids)}
    board ready column  : #{length(surfaced)}
    first 3 surfaced    : #{surfaced |> Enum.take(3) |> Enum.join(", ")}
    violations          : #{length(violations)}
    #{Enum.map_join(violations, "\n", fn v -> "  #{v.clause} #{v.doc_id}: #{v.detail}" end)}
    ────────────────────────────────────────────────────────────────────────────
    """)

    # The probe must MEASURE something: a host whose ready head is empty while
    # the corpus holds open work tells us nothing about C1, so say so loudly
    # rather than bank a green.
    assert length(ready_ids) > 0,
           "the live ready head is empty — nothing to measure (counts: #{inspect(counts)})"

    assert MapSet.disjoint?(MapSet.new(ready_ids), MapSet.new(in_progress_ids)),
           "the live overlay marks a row both ready and in-flight"

    assert violations == [],
           "claim-forward violations on the live overlay: #{inspect(violations)}"
  end

  # ── the live payload → the board's normalized card ─────────────────────────
  #
  # Only the fields `Board.build/2` reads. `blocker_statuses` is empty for a row
  # in the live READY head by construction — the server's ready gate has already
  # certified every blocker done — and irrelevant for an `in_progress` row,
  # whose bucket is its stored status. The assertion that bites is therefore the
  # LIFECYCLE one: a ready-head row whose `lifecycle_status` the board does not
  # treat as claimable buckets elsewhere and reds C0/C1.
  defp to_card(doc) do
    content = Map.get(doc, "content", %{}) || %{}

    %{
      doc_id: doc_id(doc),
      title: Map.get(doc, "title") || "",
      priority: Map.get(doc, "priority") || Map.get(content, "priority"),
      parent_id: Map.get(content, "parent_id"),
      labels: Map.get(doc, "labels") || [],
      worker: get_in(doc, ["claim", "worker"]),
      lifecycle_status: Map.get(content, "lifecycle_status") || "open",
      criteria: nil,
      github: nil,
      github_synced: false,
      blocker_statuses: [],
      sub: nil,
      next_criterion: nil,
      updated_at: parse_ts(Map.get(doc, "updated_at"))
    }
  end

  defp doc_id(doc), do: Map.get(doc, "doc_id") || Map.get(doc, "id")

  defp parse_ts(nil), do: nil

  defp parse_ts(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp fetch_prime!(url, token) do
    {:ok, resp} =
      Req.get("#{String.trim_trailing(url, "/")}/v1/tasks/prime",
        params: [limit: @limit],
        headers: [{"authorization", "Bearer #{token}"}],
        receive_timeout: 60_000
      )

    assert resp.status == 200, "prime returned #{resp.status}: #{inspect(resp.body)}"
    resp.body
  end
end
