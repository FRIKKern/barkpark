defmodule BarkparkWeb.TasksController.BriefClaimLapsedTest do
  @moduledoc """
  task-7385811ef5120f3a: a READY row's brief card must not render a claim
  block for a lease that has lapsed.

  THE SHAPE OF THE BUG. When a claim lease is swept the server nulls
  `content.claim.worker` and leaves the rest of the record — `epoch`, and the
  last `now` line the worker wrote — behind as history. The old brief rule
  (`brief_claim/1`, cut c) kept the block whenever a worker OR a now-line
  survived, so a row that is back on the queue and claimable by anyone still
  rendered `"claim": {"epoch": 3, "now": {...}}`. Measured on a live
  `bp task ready --limit 50` on 2026-09-07: 16 of 50 cards carried a claim
  block and 7 of them were worker-less.

  THE FAILURE MODE THIS FILE GUARDS IS THE OPPOSITE ONE, and it is silent:
  removing too much. A genuinely live claim — the shape every `in_progress`
  row on `/v1/tasks/prime?view=brief` has — must still ride the card, and the
  full record must still carry the history. Both are asserted below, and they
  FAIL DIFFERENTLY from the lapsed case: same function, same fixture family,
  opposite outcomes.

  MUTATION PROOF. Restore the old predicate in `brief_claim/1`:

      if is_nil(worker) and is_nil(now), do: nil, else: %{...}

  and every "lapsed" assertion here reds while every "live" assertion stays
  green. Delete the claim block unconditionally (`defp brief_claim(_), do:
  nil`) and the "live" assertions red instead. Neither mutation can pass this
  file.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  # A lapsed lease as the sweeper actually leaves it: worker nulled, epoch and
  # the last now-line intact. Taken from the residue shape on the live ready
  # page, not invented.
  @lapsed_claim %{
    "worker" => nil,
    "epoch" => 3,
    "ts_iso" => "2026-09-07T12:00:00.123456Z",
    "work_digest" => "abcd1234deadbeef",
    "now" => %{
      "text" => "wiring the serializer, tests next",
      "ts" => "2026-09-07T12:00:00.123456Z",
      "criterion" => 1
    }
  }

  # The control: the SAME record with a holder. One field apart, opposite
  # verdict.
  @live_claim Map.put(@lapsed_claim, "worker", "lead-ledger-c4")

  defp doc(doc_id, claim, extra \\ %{}) do
    %Document{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "task",
      status: "published",
      title: "Drop the claim block from ready brief cards when the lease is lapsed",
      content:
        Map.merge(
          %{"kind" => "task", "lifecycle_status" => "open", "priority" => 2, "claim" => claim},
          extra
        ),
      updated_at: ~N[2026-09-07 15:50:00]
    }
  end

  describe "the lapsed residue leaves the card" do
    test "a worker-less claim is omitted whole — no key, not a null, not an empty map" do
      card = Params.render_doc(doc("lapsed-1", @lapsed_claim), :brief)

      refute Map.has_key?(card, :claim),
             "a lapsed lease still renders a claim block: #{inspect(Map.get(card, :claim))}"

      # …and nothing ELSE on the card moved. The cut is one key wide.
      assert card.doc_id == "lapsed-1"
      assert card.priority == 2
      refute Map.has_key?(card, :lifecycle_status)
    end

    test "an epoch-only residue with no now-line is omitted too (the pre-existing case)" do
      card = Params.render_doc(doc("lapsed-2", %{"worker" => nil, "epoch" => 9}), :brief)
      refute Map.has_key?(card, :claim)
    end

    test "a claim key that is not a map at all is still omitted" do
      for junk <- [nil, "lead-ledger-c4", []] do
        card = Params.render_doc(doc("lapsed-3", junk), :brief)
        refute Map.has_key?(card, :claim), "junk claim #{inspect(junk)} rode the card"
      end
    end
  end

  describe "no ownership signal is hidden" do
    test "a LIVE claim still names its holder, epoch and now-line on the brief card" do
      card = Params.render_doc(doc("live-1", @live_claim), :brief)

      assert card.claim["worker"] == "lead-ledger-c4"
      assert card.claim["epoch"] == 3
      assert card.claim["now"]["text"] == "wiring the serializer, tests next"
      assert card.claim["now"]["criterion"] == 1
    end

    test "a live claim with NO now-line still rides — the worker alone is the signal" do
      card =
        Params.render_doc(doc("live-2", %{"worker" => "lead-ledger-c4", "epoch" => 4}), :brief)

      assert card.claim["worker"] == "lead-ledger-c4"
      assert card.claim["epoch"] == 4
      refute Map.has_key?(card.claim, "now")
    end

    test "the brief claim is still the DIET shape — full-view detail does not leak onto it" do
      card = Params.render_doc(doc("live-3", @live_claim), :brief)

      for leaked <- ["ts_iso", "work_digest", "work_field_digests", "execution_policy"] do
        refute Map.has_key?(card.claim, leaked), "#{leaked} leaked onto the brief claim"
      end
    end

    test "FULL view — the shape `bp task get <doc_id>` returns — still carries the history" do
      full = Params.render_doc(doc("lapsed-4", @lapsed_claim), :full)

      # Verbatim, worker key and all: the record is not edited, only the LIST
      # card's projection of it.
      assert full.claim == @lapsed_claim
      assert full.claim["epoch"] == 3
      assert full.claim["now"]["text"] == "wiring the serializer, tests next"
      assert full.content["claim"] == nil, "full view moves the claim to the top level"
    end
  end

  describe "truncation honesty follows the emission rule" do
    @long_now String.duplicate("now line words that ramble on ", 10)
    @short_title "Short enough to survive the ninety-six grapheme cap"
    @long_title String.duplicate("a very long slice title ", 10)

    test "a page whose ONLY over-limit field is a LAPSED now-line carries NO help line" do
      claim = put_in(@lapsed_claim, ["now", "text"], @long_now)
      d = %{doc("lapsed-help", claim) | title: @short_title}

      # Nothing on the rendered page ends in a …, so the banner must not fire.
      card = Params.render_doc(d, :brief)
      refute Map.has_key?(card, :claim)

      assert Params.maybe_put_brief_truncation_help(%{docs: []}, [d], :brief) == %{docs: []}
    end

    test "control: the SAME over-limit now-line on a LIVE claim DOES fire the help line" do
      claim = put_in(@live_claim, ["now", "text"], @long_now)
      d = %{doc("live-help", claim) | title: @short_title}

      card = Params.render_doc(d, :brief)
      assert String.length(card.claim["now"]["text"]) == 160
      assert String.ends_with?(card.claim["now"]["text"], "…")

      assert %{help: [_]} = Params.maybe_put_brief_truncation_help(%{docs: []}, [d], :brief)
    end

    test "control: a long TITLE still fires the help line on a lapsed row" do
      claim = put_in(@lapsed_claim, ["now", "text"], @long_now)
      d = %{doc("lapsed-title-help", claim) | title: @long_title}

      assert %{help: [_]} = Params.maybe_put_brief_truncation_help(%{docs: []}, [d], :brief)
    end
  end

  describe "the measured saving, both directions, on one 50-card page" do
    # The live census this row was re-anchored on: of 50 ready cards, 16 carry
    # a claim block and 7 of those are worker-less residue. The fixture below
    # reproduces exactly that mix so the delta is the one the ledger pays.
    @cards 50
    @claimed 16
    @lapsed 7

    test "the worker-less residue is fully removed and the saving is quoted" do
      docs =
        for i <- 1..@cards do
          claim =
            cond do
              i <= @lapsed -> @lapsed_claim
              i <= @claimed -> @live_claim
              true -> nil
            end

          doc("mix-#{i}", claim)
        end

      after_bytes =
        docs |> Enum.map(&Params.render_doc(&1, :brief)) |> Jason.encode!() |> byte_size()

      # BEFORE = the same page under the OLD rule, reconstructed by putting the
      # v2-shaped claim back on exactly the cards that lost one. Reconstructed
      # rather than remembered: a number typed from a previous run cannot red.
      before_bytes =
        docs
        |> Enum.map(fn d ->
          card = Params.render_doc(d, :brief)
          claim = get_in(d.content, ["claim"])

          if is_map(claim) and is_nil(Map.get(claim, "worker")) do
            Map.put(card, :claim, %{
              "epoch" => Map.get(claim, "epoch"),
              "now" => Map.take(claim["now"], ["text", "ts", "criterion"])
            })
          else
            card
          end
        end)
        |> Jason.encode!()
        |> byte_size()

      saved = before_bytes - after_bytes

      IO.puts(
        "\ntask-7385811ef5120f3a 50-card probe: before=#{before_bytes}B " <>
          "after=#{after_bytes}B saved=#{saved}B " <>
          "(#{@lapsed}/#{@cards} lapsed residues dropped, #{@claimed - @lapsed} live claims kept)"
      )

      assert after_bytes < before_bytes,
             "the residue cut saved nothing: before=#{before_bytes}B after=#{after_bytes}B"

      # Every lapsed card lost its whole block; every live card kept one. The
      # count is the claim, not the byte total, so a future field addition
      # cannot make this pass for the wrong reason.
      cards = Enum.map(docs, &Params.render_doc(&1, :brief))
      assert Enum.count(cards, &Map.has_key?(&1, :claim)) == @claimed - @lapsed

      # …AND THE CEILING IS NOT MET BY THIS SLICE. The 15,360 B bar the parent
      # epic (task-908417832622ea39) owns needs a different lever: on the live
      # page the whole residue is ~1,250 B against a ~2,200 B overrun. This
      # test measures the delta it can pay and refuses to imply the rest.
      assert saved > 0
    end
  end
end
