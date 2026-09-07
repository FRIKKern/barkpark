defmodule Barkpark.JsCoreErrorPredicateMirrorTest do
  @moduledoc """
  The ONLY lock on the `isBarkparkError` mirror between `@barkpark/core` and the
  search-starter template's dependency-free test stub.

  `templates/search-starter/lib/__test-stub-barkpark-core.mjs` hand-copies the
  runtime body of `isBarkparkError` from `js/packages/core/src/errors.ts`. The
  stub exists because the `finder-unit` CI job runs with NO install and
  `@barkpark/core` arrives as a `file:` vendor tarball, so the bare specifier
  cannot resolve there. Two copies of one predicate, each side's suite green,
  and — until this file — nothing that reds when one side moves. `doc-absence.test.ts`
  was free to keep testing a fiction.

  ## Why HERE and not in either JS suite

  A `paths:`-filtered workflow publishes no required context on a PR that does
  not match its filter. A lock living only in `js-tests` never fires on a
  `templates/search-starter/**` PR; a lock living only in `search-starter-smoke`
  never fires on a `js/packages/core/**` PR. Either one is HALF a lock.

  This file is the shape the repo already uses for cross-surface literal locks
  (`api/test/barkpark/sheets_parity_test.exs` reads
  `js/packages/react/src/blocks/sheet.ts` the same way). VENUE: workflow
  `.github/workflows/elixir.yml`, job `Test (Elixir 1.18.4 / OTP 27.0)`,
  aggregated into the REQUIRED context `Elixir gate` (one of the four in
  `.github/required-checks.json`). Both source paths are declared in
  `ELIXIR_TEST_ONLY_PATHS` in `scripts/elixir-path-escape-check.sh`, whose
  `--match test` output IS that workflow's dispatch predicate. Declaring them
  does two things at once: it makes `scripts/elixir-path-escape-check.sh` honest
  about these two repo-root reads, and it puts BOTH files in the dispatch set,
  so a PR touching either side runs this suite. That is what makes the lock
  bidirectional rather than one-directional.

  ## What is compared

  Not bytes — the two files are different languages. Both bodies are reduced to
  a canonical token form (block and line comments dropped, TypeScript `as { … }`
  assertions dropped, double quotes folded to single, semicolons dropped,
  whitespace collapsed) and compared as strings. After that reduction the two
  bodies are IDENTICAL today, so any character changed in an operator, an
  identifier, or a string literal on either side reds. Changes confined to
  comments do not — comments erase, and that is the honest boundary.

  ## Non-vacuity

  `extract_body!/2` REFUSES, loudly and with a distinct message, on an empty
  read, on a missing signature, and on an empty body. A silently-empty
  extractor comparing "" to "" is exactly the vacuous pass this lock exists to
  prevent, so the refusal arm is itself a test below.
  """
  use ExUnit.Case, async: true

  # Spelled as ONE literal each. A path assembled from a module attribute is a
  # shape scripts/elixir-path-escape-check.sh cannot resolve, and a read the
  # ratchet cannot see is worse than one it rejects.
  @core Path.expand("../../../js/packages/core/src/errors.ts", __DIR__)
  @stub Path.expand(
          "../../../templates/search-starter/lib/__test-stub-barkpark-core.mjs",
          __DIR__
        )

  test "the search-starter stub's isBarkparkError body equals @barkpark/core's" do
    core = extract_body!(@core, "js/packages/core/src/errors.ts")

    stub =
      extract_body!(
        @stub,
        "templates/search-starter/lib/__test-stub-barkpark-core.mjs"
      )

    assert core == stub,
           "isBarkparkError drifted between @barkpark/core and the search-starter " <>
             "test stub.\n" <>
             "  js/packages/core/src/errors.ts:\n    #{core}\n" <>
             "  templates/search-starter/lib/__test-stub-barkpark-core.mjs:\n    #{stub}\n" <>
             "core is the source of truth; the stub follows it. Fix the stub in the " <>
             "SAME PR as the core change.\n" <>
             "Do NOT make this green by deleting the assertion or by moving either " <>
             "body somewhere the extractor stops finding it. This is the ONLY guard " <>
             "on that mirror that runs in a context which can block a merge — the " <>
             "template's own node --test runs under search-starter-smoke, which never " <>
             "fires on a js/ PR, and core's vitest runs under js-tests, which never " <>
             "fires on a templates/ PR. Silencing it here lets doc-absence.test.ts go " <>
             "back to testing a fiction."
  end

  describe "the extractor refuses rather than passing vacuously" do
    test "an empty read REFUSES with a distinct message" do
      path =
        Path.join(System.tmp_dir!(), "bp-mirror-empty-#{System.unique_integer([:positive])}.ts")

      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      assert_raise ExUnit.AssertionError, ~r/read NOTHING/, fn ->
        extract_body!(path, "fixture/empty.ts")
      end
    end

    test "a source with no isBarkparkError signature REFUSES with a distinct message" do
      path =
        Path.join(System.tmp_dir!(), "bp-mirror-nosig-#{System.unique_integer([:positive])}.ts")

      File.write!(path, "export function somethingElse() {\n  return 1\n}\n")
      on_exit(fn -> File.rm(path) end)

      assert_raise ExUnit.AssertionError, ~r/no `isBarkparkError` implementation/, fn ->
        extract_body!(path, "fixture/nosig.ts")
      end
    end

    test "an empty body REFUSES with a distinct message" do
      path =
        Path.join(System.tmp_dir!(), "bp-mirror-nobody-#{System.unique_integer([:positive])}.ts")

      File.write!(path, "export function isBarkparkError(e, code) {\n}\n")
      on_exit(fn -> File.rm(path) end)

      assert_raise ExUnit.AssertionError, ~r/EMPTY body/, fn ->
        extract_body!(path, "fixture/nobody.ts")
      end
    end

    test "the extractor actually discriminates — a changed operand does not compare equal" do
      # Guards the guard: if normalisation ever flattened the body to a constant,
      # the equality test above would pass on any two files. It does not.
      a = normalize("if (typeof c !== 'string') return false")
      b = normalize("if (typeof c !== 'number') return false")
      refute a == b
      refute a == ""
    end
  end

  # Pull the RUNTIME body of `isBarkparkError` out of a TS or MJS source and
  # reduce it to a canonical token form. REFUSES with the path rather than
  # returning "" whenever the shape it depends on is gone.
  defp extract_body!(path, rel) do
    src = File.read!(path)

    if String.trim(src) == "" do
      flunk(
        "#{rel}: the mirror extractor read NOTHING — the file is empty or missing. " <>
          "An empty read must never compare equal to an empty read; fix the path or " <>
          "restore the file. Do NOT delete this assertion."
      )
    end

    lines = String.split(src, "\n")

    # The implementation signature is the LAST line mentioning isBarkparkError
    # that ends in `{`. TypeScript overload signatures end in a type, never a
    # brace, so they are skipped — including the multi-line one and the one
    # carrying `(string & {})`, which a naive `[^{]*` scan would trip over.
    sig_index =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} ->
        String.contains?(line, "isBarkparkError(") and
          String.ends_with?(String.trim_trailing(line), "{")
      end)
      |> List.last()

    idx =
      case sig_index do
        {_line, i} ->
          i

        nil ->
          flunk(
            "#{rel}: found no `isBarkparkError` implementation signature (a line " <>
              "naming isBarkparkError( and ending in `{`). If it was renamed or " <>
              "restructured, update this extractor — do NOT delete the assertion, it " <>
              "is the only lock on this mirror that runs in a required context."
          )
      end

    body =
      lines
      |> Enum.drop(idx + 1)
      |> Enum.take_while(fn line -> not String.match?(line, ~r/^\}/) end)
      |> Enum.join("\n")
      |> normalize()

    if body == "" do
      flunk(
        "#{rel}: extracted an EMPTY body for isBarkparkError. A lock that compares " <>
          "nothing to nothing is vacuous; fix the extractor or the source."
      )
    end

    body
  end

  # TS and JS spell the same runtime differently. Reduce both to one form.
  defp normalize(body) do
    body
    # /** … */ and /* … */ — this is what erases the stub's JSDoc type cast
    |> String.replace(~r|/\*.*?\*/|s, " ")
    # // … to end of line
    |> String.replace(~r|//[^\n]*|, " ")
    # TypeScript `as { … }` assertions erase at runtime
    |> String.replace(~r/\s+as\s+\{[^}]*\}/, "")
    |> String.replace("\"", "'")
    |> String.replace(";", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
