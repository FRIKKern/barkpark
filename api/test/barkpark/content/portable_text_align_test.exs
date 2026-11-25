defmodule Barkpark.Content.PortableTextAlignTest do
  @moduledoc """
  task-dd2886673f171e40 (#28714 review N1): the line-up `PortableTextMerge`
  and `PortableTextPairing` share.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableTextAlign, as: Align

  test "a longest common subsequence, in order" do
    assert Align.pairs(~w(a b c d), ~w(a x c d)) == [{0, 0}, {2, 2}, {3, 3}]
    assert Align.pairs(~w(c b a), ~w(a b c)) == [{2, 0}]
    assert Align.pairs([], ~w(a)) == []
  end

  test "a copy above a block: the block where the other list has it is paired" do
    assert Align.pairs(~w(x p x q), ~w(p x q)) == [{1, 0}, {2, 1}, {3, 2}]
  end

  test "the sameness is the caller's" do
    assert Align.pairs(~w(A b), ~w(a B), &(String.downcase(&1) == String.downcase(&2))) ==
             [{0, 0}, {1, 1}]
  end

  test "the gaps between the pairs, empty ones too" do
    assert Align.gaps([{1, 0}, {2, 2}], 4, 3) == [{-1, [0], []}, {1, [], [1]}, {2, [3], []}]
  end
end
