defmodule Barkpark.StudioChat.AgentTaskJoinLiveCorpusTest do
  @moduledoc """
  The agent↔task join against the LIVE corpus (task-ba42f986bb0d4594,
  criterion "a live-corpus arm reports the ambiguous population rather than
  assuming it is empty"). The Elixir twin of the Go liveprobe arm in
  internal/taskboard/live_probe_test.go, printing the SAME four figures on the
  same line shape so the two surfaces can be diffed on one corpus.

  READ-ONLY and opt-in. It reads a corpus FILE, never a database: the output of
  a read-only listing, e.g.

      env -u BARKPARK_TOKEN bp task ls --all -o json > /tmp/corpus.json
      BARKPARK_LIVE_CORPUS=/tmp/corpus.json \\
        mix test --include live_probe \\
        test/barkpark/studio_chat/agent_task_join_live_corpus_test.exs

  Tagged `:live_probe` (excluded by default in test_helper.exs, like the Go
  side's `-tags liveprobe`), and it FLUNKS rather than skipping when opted in
  without a corpus, so an opt-in run can never go green on nothing.
  """
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.AgentTaskJoin, as: J

  @moduletag :live_probe

  test "every live key resolves to its own row or to nothing; the ambiguous population is reported" do
    path = System.get_env("BARKPARK_LIVE_CORPUS")
    assert is_binary(path) and File.exists?(path), "set BARKPARK_LIVE_CORPUS to a bp task ls JSON"

    rows =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("docs")
      |> Enum.map(&%{doc_id: &1["doc_id"], title: &1["title"]})

    assert rows != [], "the corpus file holds no rows — nothing was measured"

    index = J.index(rows)

    over_budget =
      rows
      |> Enum.uniq_by(&Barkpark.Content.DraftId.published_id(&1.doc_id))
      |> Enum.count(&(is_binary(&1.title) and byte_size(J.full_slug(&1.title)) > 40))

    ambiguous = J.ambiguous(index)
    ambiguous_rows = ambiguous |> Enum.map(fn {_k, ids} -> length(ids) end) |> Enum.sum()

    joined =
      Enum.count(Map.keys(index), fn key ->
        case J.join(index, "build:" <> key) do
          {:ok, %{row: row}} ->
            # the contract: a key that resolves resolves to a row whose OWN
            # emitted or uncapped slug IS that key
            assert key in [J.emitter_slug(row.title), J.full_slug(row.title)]
            true

          :none ->
            false
        end
      end)

    # an ambiguous key must resolve to nothing, never a best guess
    for {key, _ids} <- ambiguous, do: assert(:none == J.join(index, "build:" <> key))

    IO.puts(
      "agent-task join (elixir): rows=#{length(rows)} distinct-keys=#{map_size(index)} " <>
        "over-40-char-titles=#{over_budget} ambiguous-keys=#{length(ambiguous)} " <>
        "ambiguous-rows=#{ambiguous_rows} joined-keys=#{joined}"
    )

    for {key, ids} <- ambiguous |> Enum.sort() |> Enum.take(5),
        do: IO.puts("  ambiguous #{key} -> #{Enum.join(ids, ", ")}")

    # If the corpus stopped exercising the cap, the fixture arms are the only
    # proof left — say so loudly instead of passing quietly.
    assert over_budget > 0,
           "no live title slugs past 40 chars — the cap is untested by the corpus"

    assert joined + length(ambiguous) == map_size(index)
  end
end
