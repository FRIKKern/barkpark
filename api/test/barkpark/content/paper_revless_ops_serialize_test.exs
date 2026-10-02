defmodule Barkpark.Content.PaperRevlessOpsSerializeTest do
  @moduledoc """
  Revision-less block ops on one paper serialize instead of clobbering
  (task-5e4d72fdaadfecab, first half; r2-lane-b paper write-path audit).

  `POST /v1/plugins/bulldocs/papers/:slug/ops` without `ifRev` loaded the paper,
  applied the op to its block array and wrote the WHOLE array back with a plain
  `UPDATE … WHERE id = pk`. Two concurrent appends both read rev N; the second
  write dropped the first's block. The API is unchanged — a rev-less op still
  needs no revision — but the write is now compare-and-set on the row rev it
  read, and a lost race re-reads and re-applies the op, so both appends land.
  No lock is taken (no new lock order next to the audit-chain locks).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "production"

  defp seed!(slug) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "p0",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Seed"}]
            }
          ]
        })
      )

    slug
  end

  defp append(id) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => id}]
      }
    }
  end

  defp ids(slug), do: slug |> Content.paper_blocks(@dataset) |> Enum.map(& &1["id"])

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  test "an append committed between another append's read and write is not clobbered" do
    slug = seed!("revless-race-#{System.unique_integer([:positive])}")
    parent = self()

    # The test seam fires in the window between the op's read and its write: a
    # second rev-less append commits there, exactly the concurrent producer.
    racer = fn ->
      send(parent, :racer_ran)
      {:ok, _} = Content.apply_paper_block_op(slug, append("b"), @dataset)
    end

    assert {:ok, _} =
             Content.apply_paper_block_op(slug, append("a"), @dataset,
               before_fenced_write: once(racer)
             )

    assert_received :racer_ran
    assert Enum.sort(ids(slug)) == ["a", "b", "p0"]
  end

  test "concurrent rev-less appends on one paper all survive" do
    slug = seed!("revless-many-#{System.unique_integer([:positive])}")
    want = for n <- 1..8, do: "c#{n}"

    want
    |> Enum.map(fn id ->
      Task.async(fn -> Content.apply_paper_block_op(slug, append(id), @dataset) end)
    end)
    |> Enum.each(fn task -> assert {:ok, _} = Task.await(task, 30_000) end)

    assert Enum.sort(ids(slug)) == Enum.sort(["p0" | want])
  end

  test "an explicit ifRev keeps its precondition contract (412, no retry)" do
    slug = seed!("revless-ifrev-#{System.unique_integer([:positive])}")

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_op(slug, append("x"), @dataset, if_rev: 999)

    assert ids(slug) == ["p0"]
  end

  # The seam runs at most once: the retried attempt must not re-race itself.
  defp once(fun) do
    ref = make_ref()

    fn ->
      unless Process.get(ref) do
        Process.put(ref, true)
        fun.()
      end
    end
  end
end
