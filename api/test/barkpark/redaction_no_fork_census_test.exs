defmodule Barkpark.RedactionNoForkCensusTest do
  @moduledoc """
  Guards the `@canonical capability:secret-redaction` marker on
  `Barkpark.Redaction` by asserting the property the marker CLAIMS: no other
  module under `api/lib` carries a private, key-name-shaped secrecy predicate of
  its own.

  `Barkpark.EpicFleet.Benchmark` used to hold a character-identical private
  `sensitive_key?/1` plus its own `[REDACTED]` tables. It now calls
  `Barkpark.Redaction.redact_sensitive/1`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Redaction

  # A private predicate whose NAME says it decides whether a key names a secret
  # — `sensitive_key?`, `secret_key?`, `redacted_key?`, and prefixed variants.
  @fork_shape ~r/^\s*defp\s+[a-z_]*(sensitive|secret|redact)[a-z_]*_key\?/m

  defp lib_root do
    Path.expand("../../lib", __DIR__)
  end

  defp scan(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(@fork_shape, line) end)
      |> Enum.map(fn {line, n} ->
        {Path.relative_to(file, root), n, String.trim(line)}
      end)
    end)
  end

  describe "secret-redaction has exactly one owner" do
    test "the scanner FINDS a planted specimen (so an empty result is evidence, not a failed read)" do
      root =
        Path.join(
          System.tmp_dir!(),
          "redaction_fork_census_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "nested"))

      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "nested/planted_fork.ex"), """
      defmodule Planted.Fork do
        defp sanitize(map) do
          Map.new(map, fn {k, v} -> if sensitive_key?(k), do: {k, "[REDACTED]"}, else: {k, v} end)
        end

        defp sensitive_key?(key), do: key in ~w(token password)
      end
      """)

      assert [
               {"nested/planted_fork.ex", 6,
                "defp sensitive_key?(key), do: key in ~w(token password)"}
             ] =
               scan(root)
    end

    test "no forked sensitive-key predicate survives under api/lib" do
      survivors = scan(lib_root())

      assert survivors == [],
             "forked secret-redaction predicates found — converge them onto " <>
               "Barkpark.Redaction.sensitive_key?/1:\n" <>
               Enum.map_join(survivors, "\n", fn {f, n, l} -> "  #{f}:#{n}: #{l}" end)
    end

    test "the one owner still scrubs the shapes the retired fork covered" do
      assert Redaction.sensitive_key?("api-key")
      assert Redaction.sensitive_key?("runnerAccess-Token")
      assert Redaction.sensitive_key?("userPassWord")
      assert Redaction.sensitive_key?("runner_credentials")
      refute Redaction.sensitive_key?("runner_id")
      refute Redaction.sensitive_key?("tokenizer")

      assert Redaction.redact_sensitive(%{
               "api-key" => "live",
               "nested" => %{"webhook_secret" => "hook", "keep" => "plain"},
               "list" => [%{"password" => "p"}, "untouched"]
             }) == %{
               "api-key" => "[REDACTED]",
               "nested" => %{"webhook_secret" => "[REDACTED]", "keep" => "plain"},
               "list" => [%{"password" => "[REDACTED]"}, "untouched"]
             }
    end

    test "redact_sensitive/1 leaves JSON-looking binaries byte-identical (that is redact/3's job)" do
      json = ~s({"api_key":"live-secret"})

      assert Redaction.redact_sensitive(json) == json
      assert Redaction.redact(json, [], ["api_key"]) == ~s({"api_key":"[REDACTED]"})
    end
  end
end
