defmodule BarkparkWeb.Studio.StudioLive.Shared.PaperBacklinksPartitionTest do
  @moduledoc """
  Unit tests for `Paper.partition_backlinks/1` (lvw-t3) — the pure three-way
  partition the Studio backlinks panel renders from one
  `Content.Graph.reverse_referencers/2` result:

    * `used_by` — `valueref`-kind referencers (the used-by / impact list for a
      canonical value doc). Kind wins over origin: a valueref edge carries
      `plugin_source: "bulldocs"` (the #714 body-walk extractor) but must NOT
      land in the derived bucket.
    * `linked`  — `plugin_source == nil` (direct schema-field references).
    * `derived` — the remaining plugin-derived referencers.

  Scoping is NOT re-tested here: out-of-scope referencers never reach this
  function (reverse_referencers drops them fail-closed upstream, MEDIUM-5).
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  defp ref(kind, plugin_source, doc_id) do
    %{
      from_id: "uuid-#{doc_id}",
      from_doc_id: doc_id,
      title: doc_id,
      type: "paper",
      kind: kind,
      via_field: kind,
      plugin_source: plugin_source
    }
  end

  test "valueref goes to used_by even though plugin_source is set; the rest split on origin" do
    valueref = ref("valueref", "bulldocs", "p-impact")
    linked = ref("references", nil, "p-linked")
    derived = ref("references", "bulldocs", "p-derived")

    assert Paper.partition_backlinks([valueref, linked, derived]) ==
             {[valueref], [linked], [derived]}
  end

  test "empty input yields three empty buckets (the panel's empty state)" do
    assert Paper.partition_backlinks([]) == {[], [], []}
  end

  test "order within each bucket is preserved (the engine's inserted_at ASC ranking)" do
    v1 = ref("valueref", "bulldocs", "p-first-user")
    v2 = ref("valueref", "bulldocs", "p-second-user")

    assert {[^v1, ^v2], [], []} = Paper.partition_backlinks([v1, v2])
  end
end
