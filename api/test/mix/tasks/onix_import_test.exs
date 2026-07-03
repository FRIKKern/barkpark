defmodule Mix.Tasks.Onix.ImportTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Onix.Import

  # These tests pin the exit-code contract: mix onix.import must FAIL LOUDLY
  # (raise Mix.Error → non-zero exit) instead of silently exiting 0 when the
  # import did nothing useful. The two silent-success bugs are:
  #   1. every product failed → previously exited 0
  #   2. zero <Product> elements matched → previously exited 0

  describe "summarize/1 (per-product exit-code contract)" do
    test "all products ok → :ok, no raise" do
      assert Import.summarize([:ok, :ok, :ok]) == :ok
    end

    test "any product failed → raises Mix.Error (non-zero exit)" do
      assert_raise Mix.Error, ~r/1 of 3 product\(s\) failed/, fn ->
        Import.summarize([:ok, :error, :ok])
      end
    end

    test "every product failed → raises Mix.Error (non-zero exit)" do
      assert_raise Mix.Error, ~r/2 of 2 product\(s\) failed/, fn ->
        Import.summarize([:error, :error])
      end
    end
  end

  describe "run/1 (zero-product no-op)" do
    test "0 <Product> parsed → raises Mix.Error mentioning the namespace hint" do
      path = Path.join(System.tmp_dir!(), "onix-empty-#{System.unique_integer([:positive])}.xml")

      # Valid ONIX-ish envelope with NO <Product> elements. --dry-run so the
      # task never touches app.start / the DB; it must still fail non-zero.
      File.write!(path, ~s(<?xml version="1.0"?><ONIXMessage><Header/></ONIXMessage>))

      try do
        assert_raise Mix.Error, ~r/0 <Product> elements parsed/, fn ->
          Import.run([path, "--dry-run"])
        end
      after
        File.rm(path)
      end
    end
  end
end
