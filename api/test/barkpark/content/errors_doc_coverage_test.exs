defmodule Barkpark.Content.ErrorsDocCoverageTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Errors

  # ── Human docs §9 must document EVERY served error code ──────────────────────
  #
  # `Content.Errors.known_codes/0` is the single source of the public v1 error
  # vocabulary: it drives the OpenAPI `Error.code` enum (openapi.ex) and is
  # meant to be mirrored, human-readable, in docs/api-v1.md §9. A contract test
  # already pins enum == known_codes — but NOTHING pinned the MARKDOWN, so a new
  # code (workspace_suspended 403, quota_exceeded 402 from perfect-plan-build W1,
  # and five older ones) could enter known_codes/0 and the served enum while §9
  # silently under-reported them. A client reading the hand-written contract then
  # meets a `code` the docs never named.
  #
  # This is the anti-drift RATCHET the api-v1 §9 finding asked for: every code the
  # runtime can emit must appear, verbatim in backticks, somewhere in §9 (the
  # core/additive/endpoint prose). Add a code to known_codes/0 without documenting
  # it and this fails — so playground_expired (the W2c playground TTL reaper's
  # 403) cannot fall behind either.
  #
  # The doc is located relative to THIS file so the test is cwd-independent:
  # api/test/barkpark/content/ → repo root → docs/api-v1.md.
  @api_v1_doc Path.expand("../../../../docs/api-v1.md", __DIR__)

  defp section_9 do
    doc = File.read!(@api_v1_doc)

    # §9 spans from its own heading up to the next top-level "## " heading.
    [_preamble, from_9] = String.split(doc, "## 9. Error Codes", parts: 2)

    from_9
    |> String.split(~r/\n## \d+/, parts: 2)
    |> List.first()
  end

  test "docs/api-v1.md §9 exists and is non-trivial" do
    section = section_9()

    # Guard against a silent rename/deletion of §9 making the coverage assertion
    # vacuously pass over an empty string.
    assert is_binary(section)
    assert String.length(section) > 200
    # Stable sentinels that live INSIDE §9 (the split consumes the heading) — if a
    # rewrite removes these the section shape changed and coverage must be re-checked.
    assert section =~ "All errors:"
    assert section =~ "known_codes"
  end

  test "every Content.Errors.known_codes/0 code is documented in §9" do
    section = section_9()

    missing =
      Errors.known_codes()
      |> Enum.reject(fn code -> String.contains?(section, "`#{code}`") end)
      |> Enum.sort()

    assert missing == [],
           "docs/api-v1.md §9 is missing #{length(missing)} error code(s) that " <>
             "Content.Errors.known_codes/0 can emit: #{Enum.join(missing, ", ")}. " <>
             "Add each (with its HTTP status + one-line meaning) to §9 so the served " <>
             "vocabulary and the human contract cannot drift."
  end

  test "the wave-1 workspace codes are documented (regression pin)" do
    # The two codes the finding named explicitly — pinned by name so a future
    # §9 rewrite that drops them is caught even if known_codes/0 also churns.
    section = section_9()

    assert section =~ "`workspace_suspended`",
           "workspace_suspended (403) must stay documented in §9"

    assert section =~ "`quota_exceeded`",
           "quota_exceeded (402) must stay documented in §9"
  end
end
