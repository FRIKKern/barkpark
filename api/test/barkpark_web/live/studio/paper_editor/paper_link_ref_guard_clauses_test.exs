defmodule BarkparkWeb.Studio.PaperEditor.PaperLinkRefGuardClausesTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  # The cap lives in a private module attribute with no accessor, so the threshold is
  # MEASURED here rather than restated: doubling a round-trip-clean pad until the guard
  # refuses locates a refused size, and a binary search between the last admitted size and
  # that one locates the boundary. No assertion below names a byte count; every size in
  # play is whatever the compiled attribute makes it, so moving the constant moves the test.
  @doubling_steps 20

  test "cap clause withholds the guard for an identity whose encoding crosses the measured ceiling" do
    refused = first_refused_pad(1, @doubling_steps)

    assert is_integer(refused),
           "paper_link_ref_guard/1 admitted every padded identity up to #{@doubling_steps} doublings: the size cap never refuses"

    boundary = last_admitted_pad(div(refused, 2), refused)

    assert boundary > 0
    assert boundary < refused
    assert boundary == last_admitted_pad(div(refused, 2), refused)

    # positive control: the same identity, one pad byte smaller, is admitted end to end
    assert is_binary(Blocks.paper_link_ref_guard(padded_ref(boundary)))

    assert {:ok, %{slug: "target", guard: guard}} =
             Blocks.paper_link_reference_copy_admission(paper_links([padded_ref(boundary)]), 0)

    assert is_binary(guard)

    # across the threshold: one pad byte more and the guard is withheld, which collapses
    # the reference-copy admission
    over = padded_ref(boundary + 1)

    assert is_nil(Blocks.paper_link_ref_guard(over)),
           "an identity one byte past the measured ceiling still produced a guard"

    assert {:error, :paper_link_reference_copy_unavailable} =
             Blocks.paper_link_reference_copy_admission(paper_links([over]), 0)
  end

  test "round-trip clause withholds the guard for a small identity JSON does not preserve" do
    lossy = ref_with_unknown(%{atom_key: 1})
    faithful = ref_with_unknown(%{"atom_key" => 1})

    # the encode clause passes for both: only the decoded === identity clause separates them
    assert {:ok, encoded} = Jason.encode(lossy)
    assert {:ok, decoded} = Jason.decode(encoded)
    refute decoded === lossy
    assert Jason.decode!(Jason.encode!(faithful)) === faithful

    assert is_nil(Blocks.paper_link_ref_guard(lossy)),
           "an identity that does not survive a JSON round trip still produced a guard"

    assert {:error, :paper_link_reference_copy_unavailable} =
             Blocks.paper_link_reference_copy_admission(paper_links([lossy]), 0)

    # positive control: the same identity with a JSON-faithful key is admitted end to end
    assert is_binary(Blocks.paper_link_ref_guard(faithful))

    assert {:ok, %{slug: "target", guard: guard}} =
             Blocks.paper_link_reference_copy_admission(paper_links([faithful]), 0)

    assert is_binary(guard)
  end

  defp first_refused_pad(_pad, 0), do: nil

  defp first_refused_pad(pad, steps) do
    if admitted_pad?(pad), do: first_refused_pad(pad * 2, steps - 1), else: pad
  end

  defp last_admitted_pad(low, high) when high - low <= 1, do: low

  defp last_admitted_pad(low, high) do
    mid = div(low + high, 2)
    if admitted_pad?(mid), do: last_admitted_pad(mid, high), else: last_admitted_pad(low, mid)
  end

  defp admitted_pad?(pad), do: is_binary(Blocks.paper_link_ref_guard(padded_ref(pad)))

  defp padded_ref(pad), do: ref_with_unknown(%{"pad" => String.duplicate("a", pad)})

  defp ref_with_unknown(unknown),
    do: %{
      "slug" => "target",
      "prefer_authored_copy" => true,
      "unknown" => unknown
    }

  defp paper_links(refs),
    do: %{
      "id" => "links",
      "type" => "paper-links",
      "layout" => "chapters",
      "refs" => refs
    }
end
