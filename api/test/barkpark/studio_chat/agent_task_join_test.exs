defmodule Barkpark.StudioChat.AgentTaskJoinTest do
  @moduledoc """
  The Elixir port of the agent↔task join (task-ba42f986bb0d4594). Each arm here
  has a Go twin in internal/taskboard/agentjoin_test.go, and uses the SAME live
  titles, so the two surfaces are held to one rule.

  The three arms the row demands, and what each one discriminates:

    * RED arm — a REAL live long title and the label its emitter produced. Drop
      the 40-character slice from `emitter_slug/1` and it fails; it asserts the
      specific doc_id, so it cannot pass on "some match".
    * QUIET arm — ambiguous, absent and non-slug labels resolve to `:none`.
    * CONTROL — the quiet arm alone passes on a join that matches NOTHING, ever.
      The control removes the collision and requires the same key to join, so
      a join degenerated to always-`:none` reds here while the quiet arm stays
      green (and deleting the ambiguity guard reds the quiet arm while this
      stays green).
  """
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.AgentTaskJoin, as: J

  # Verbatim live row (doc_id dr-w10-f1-zombied-run-remediation); its slug is
  # 69 characters and the emitter slices it to 40, landing on "re-d".
  @live_long_title "A ZOMBIED run is detected but never re-dispatched — the remediation half"
  @live_trailing_hyphen_label "build:a-zombied-run-is-detected-but-never-re-d"

  defp row(doc_id, title, extra \\ %{}), do: Map.merge(%{doc_id: doc_id, title: title}, extra)

  describe "RED arm — the 40-character emitter slice" do
    test "the live emitter label joins its row, and ONLY through the capped slug" do
      full = J.full_slug(@live_long_title)
      # premise, visible rather than assumed: the uncapped slug cannot produce
      # this label's key, so a cap-less join has nothing to match
      assert byte_size(full) > 40
      refute String.ends_with?(full, "-")
      refute full == "a-zombied-run-is-detected-but-never-re-d"

      index =
        J.index([
          row("dr-w10-f1-zombied-run-remediation", @live_long_title),
          row("unrelated", "Some other row entirely")
        ])

      assert {:ok, j} = J.join(index, @live_trailing_hyphen_label)
      assert j.row.doc_id == "dr-w10-f1-zombied-run-remediation"
      assert j.key == "a-zombied-run-is-detected-but-never-re-d"
      assert j.deep_link == "/admin/projects?task=dr-w10-f1-zombied-run-remediation"
    end

    # The wire's own answers, computed by the Go side running the verbatim
    # workflow slug() over the live corpus (agentjoin_test.go
    # TestAgentEmitterSlugMatchesTheWorkflowEmitter) — shared, not re-derived.
    test "emitter_slug/1 equals the workflow emitter on live titles" do
      for {title, want} <- [
            {@live_long_title, "a-zombied-run-is-detected-but-never-re-d"},
            {"deployments.status is an unconstrained varchar, so an unknown status enters the census as silent success",
             "deployments-status-is-an-unconstrained-v"},
            {"The Console gate's nothing-ran green is announced by a single ::notice:: annotation, and GitHub caps annotations at 10 per level per step",
             "the-console-gate-s-nothing-ran-green-is-"},
            {"Rewire the fold", "rewire-the-fold"}
          ] do
        assert J.emitter_slug(title) == want, "emitter_slug(#{inspect(title)})"
      end
    end

    test "the slice is NOT re-trimmed: a trailing hyphen survives" do
      assert J.emitter_slug(@live_long_title) |> byte_size() == 40

      assert J.emitter_slug(
               "The Console gate's nothing-ran green is announced by a single notice"
             ) ==
               "the-console-gate-s-nothing-ran-green-is-"
    end
  end

  describe "the grammar — the LAST colon-segment, not workflow_label_parts/1" do
    test "one-segment and two-segment emitter labels land on the same row" do
      index = J.index([row("t-1", "Rewire the fold")])

      for label <- ["build:rewire-the-fold", "build:console:rewire-the-fold"] do
        assert {:ok, %{row: %{doc_id: "t-1"}, key: "rewire-the-fold"}} = J.join(index, label)
      end
    end

    test "the display grammar would have yielded a different, non-joining token" do
      assert {:pair, "build", "console:rewire-the-fold"} =
               Barkpark.StudioChat.workflow_label_parts("build:console:rewire-the-fold")

      assert {:ok, "rewire-the-fold"} = J.label_key("build:console:rewire-the-fold")
    end
  end

  describe "QUIET arm — ambiguous, absent and non-slug labels resolve to nothing" do
    @colliding_a "Historical smoke record cmux smoke t2 1700"
    @colliding_b "Historical smoke record cmux smoke t2 1701"

    test "an ambiguous emitter key resolves to :none" do
      # premise: two genuinely different titles, one 40-character slug
      refute @colliding_a == @colliding_b
      assert J.emitter_slug(@colliding_a) == J.emitter_slug(@colliding_b)

      index = J.index([row("a-1", @colliding_a), row("a-2", @colliding_b)])
      assert :none == J.join(index, "build:" <> J.emitter_slug(@colliding_a))

      assert [{_key, ids}] =
               J.ambiguous(index) |> Enum.filter(fn {k, _} -> byte_size(k) == 40 end)

      assert Enum.sort(ids) == ["a-1", "a-2"]
    end

    test "an absent key and every non-slug label resolve to :none" do
      index = J.index([row("a-1", @colliding_a)])
      assert :none == J.join(index, "build:nothing-named-this")

      for label <- ["Digest the survey", "verify:Encryption Leak", "build:", "", "   ", nil, 42] do
        assert :none == J.join(index, label), "label #{inspect(label)} joined to something"
      end
    end

    test "a drafts twin of the same row is one candidate, and the link is bare" do
      index = J.index([row("drafts.t-9", "Rewire the fold"), row("t-9", "Rewire the fold")])
      assert {:ok, j} = J.join(index, "build:rewire-the-fold")
      assert j.row.doc_id == "t-9"
      assert j.deep_link == "/admin/projects?task=t-9"
    end
  end

  describe "CONTROL — the join has not degenerated to always-nothing" do
    test "the SAME colliding key joins once the collision is gone" do
      key = "build:" <> J.emitter_slug("Historical smoke record cmux smoke t2 1700")

      index =
        J.index([
          row("a-1", "Historical smoke record cmux smoke t2 1700"),
          row("b-1", "Something with a completely different name")
        ])

      assert {:ok, %{row: %{doc_id: "a-1"}}} = J.join(index, key)
    end
  end

  describe "summary/2 — segment for segment taskboard.AgentTaskSummary" do
    @now ~U[2026-09-17 04:00:00Z]

    test "a bare row paints no meter and no now-line" do
      {:ok, j} = J.join(J.index([row("t-1", "Rewire the fold")]), "build:rewire-the-fold")
      got = J.summary(j, @now)
      assert got == "t-1 · /admin/projects?task=t-1"
      refute got =~ "0/0"
      refute got =~ "▸"
    end

    test "a pulsed row with criteria matches the Go golden byte for byte" do
      rich =
        row("t-1", "Rewire the fold", %{
          criteria: %{met: 2, total: 4},
          pulse:
            J.decode_pulse(%{
              "text" => "writing the join helper",
              "ts" => DateTime.to_iso8601(DateTime.add(@now, -7 * 60))
            })
        })

      {:ok, j} = J.join(J.index([rich]), "build:rewire-the-fold")

      assert J.summary(j, @now) ==
               "t-1 · 2/4 criteria · ▸ writing the join helper (7m) · /admin/projects?task=t-1"
    end

    test "decode_pulse/1 tolerates the shapes the wire can carry" do
      assert nil == J.decode_pulse(nil)
      assert nil == J.decode_pulse(%{"text" => "   "})
      assert nil == J.decode_pulse("a legacy string now-line")
      assert %{text: "x", at: nil} == J.decode_pulse(%{"text" => "x", "ts" => "not a time"})
    end

    test "compact_age/1 buckets like the Go compactAge" do
      assert J.compact_age(-30) == "now"
      assert J.compact_age(59) == "now"
      assert J.compact_age(60) == "1m"
      assert J.compact_age(3_599) == "59m"
      assert J.compact_age(3_600) == "1h"
      assert J.compact_age(86_400) == "1d"
    end
  end

  describe "rail_agent_labels/1" do
    test "reads every workflow_agent label across workflow-bearing entries, once" do
      rail = %{
        "a" => %{
          "seq" => 2,
          "workflow" => [
            %{"type" => "workflow_phase", "title" => "Build"},
            %{"type" => "workflow_agent", "label" => "build:x"},
            %{"type" => "workflow_agent", "label" => "build:y"}
          ]
        },
        "b" => %{"seq" => 1, "workflow" => [%{"type" => "workflow_agent", "label" => "build:x"}]},
        "c" => %{"seq" => 3, "tool" => "Bash"}
      }

      assert J.rail_agent_labels(rail) == ["build:x", "build:y"]
      assert J.rail_agent_labels(nil) == []
    end
  end
end
