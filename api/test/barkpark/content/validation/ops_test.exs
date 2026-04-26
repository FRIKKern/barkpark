defmodule Barkpark.Content.Validation.OpsTest do
  # The Validation.Registry is a singleton ETS table populated at boot —
  # tests that exercise registered checkers must not run concurrently
  # with registry tests.
  use ExUnit.Case, async: false

  alias Barkpark.Content.Validation.Ops

  describe ":eq" do
    test "true on equal scalars" do
      assert Ops.eval(:eq, "epub", "epub")
      assert Ops.eval(:eq, 1, 1)
    end

    test "false on unequal scalars" do
      refute Ops.eval(:eq, "epub", "pdf")
    end

    test "deep equality on maps and lists" do
      assert Ops.eval(:eq, %{"a" => 1}, %{"a" => 1})
      refute Ops.eval(:eq, %{"a" => 1}, %{"a" => 2})
    end
  end

  describe ":in" do
    test "true when lhs is a member of the list" do
      assert Ops.eval(:in, "epub", ["pdf", "epub", "html"])
    end

    test "false on non-member" do
      refute Ops.eval(:in, "mobi", ["pdf", "epub"])
    end

    test "false when rhs is not a list" do
      refute Ops.eval(:in, "x", "x")
    end
  end

  describe ":nonempty" do
    test "false on blanks" do
      refute Ops.eval(:nonempty, nil, nil)
      refute Ops.eval(:nonempty, "", nil)
      refute Ops.eval(:nonempty, [], nil)
      refute Ops.eval(:nonempty, %{}, nil)
    end

    test "true on populated values" do
      assert Ops.eval(:nonempty, "x", nil)
      assert Ops.eval(:nonempty, [1], nil)
      assert Ops.eval(:nonempty, %{a: 1}, nil)
      assert Ops.eval(:nonempty, 0, nil)
    end
  end

  describe ":contains_all" do
    test "true when every required element is present" do
      assert Ops.eval(:contains_all, ["a", "b", "c"], ["a", "b"])
    end

    test "false on missing element" do
      refute Ops.eval(:contains_all, ["a"], ["a", "b"])
    end

    test "false when types don't match" do
      refute Ops.eval(:contains_all, "abc", ["a"])
    end

    test "trivially true with empty rhs" do
      assert Ops.eval(:contains_all, ["a"], [])
    end
  end

  describe ":starts_with" do
    test "true on prefix match" do
      assert Ops.eval(:starts_with, "978-foo", "978")
    end

    test "false on non-prefix" do
      refute Ops.eval(:starts_with, "abc", "978")
    end

    test "false on non-string lhs" do
      refute Ops.eval(:starts_with, 12_345, "12")
    end
  end

  describe "{:matches, checker}" do
    test "delegates to a built-in checker → :ok" do
      # 9780306406157 is a valid ISBN-13.
      assert Ops.eval({:matches, "isbn13"}, "9780306406157", nil)
    end

    test "false when checker returns {:error, _}" do
      refute Ops.eval({:matches, "isbn13"}, "9780306406158", nil)
    end

    test "false when checker is unknown" do
      refute Ops.eval({:matches, "no_such_checker_xyz"}, "x", nil)
    end

    test "false when checker raises (defensive — invalid args)" do
      refute Ops.eval({:matches, "isbn13"}, 12_345, nil)
    end
  end

  describe "code/1" do
    test "atoms stringify directly" do
      assert "eq" = Ops.code(:eq)
      assert "nonempty" = Ops.code(:nonempty)
    end

    test "matches encodes checker name" do
      assert "matches:isbn13" = Ops.code({:matches, "isbn13"})
    end
  end
end
