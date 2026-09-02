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

  # §9's endpoint-specific tail now lives in its own capped doc. docs/api-v1.md
  # sat on 1 B of a 14,000 B budget cap, so the paragraph naming the endpoint
  # codes was relocated to docs/api/error-codes.md and §9 kept a markdown link
  # to it. THE DOCUMENTED VOCABULARY IS THEREFORE THE UNION, AND READING EITHER
  # HALF ALONE IS A LIE — measured against known_codes/0 (84 codes) on the tree
  # that shipped this: §9 alone leaves 50 undocumented (that is the real red
  # this relocation produced before the amendment, not the 39 the filing
  # predicted), the relocated file alone leaves 34, and the union leaves 0.
  @error_codes_doc Path.expand("../../../../docs/api/error-codes.md", __DIR__)

  defp section_9 do
    doc = File.read!(@api_v1_doc)

    # §9 spans from its own heading up to the next top-level "## " heading.
    [_preamble, from_9] = String.split(doc, "## 9. Error Codes", parts: 2)

    from_9
    |> String.split(~r/\n## \d+/, parts: 2)
    |> List.first()
  end

  # File.read! and not File.read: a missing relocated doc must RAISE, not
  # silently shrink the vocabulary back to §9 and re-open the drift this file
  # exists to close.
  defp relocated_doc, do: File.read!(@error_codes_doc)

  defp documented_vocabulary, do: section_9() <> "\n" <> relocated_doc()

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

  test "§9 still points at the relocated doc, and that doc is non-trivial" do
    section = section_9()

    # THE UNION'S ANTI-VACUITY PIN. The coverage assertion below reads two files
    # and passes if EITHER names a code — so a §9 that quietly drops the pointer,
    # or a relocated file emptied to a header, would leave the union technically
    # green while a reader of the contract could no longer reach half of it.
    # docs-anchors-check §3c only resolves `](path.md)` syntax, so the link is
    # pinned in that exact form: an inline-backtick pointer rots silently.
    assert section =~ "](api/error-codes.md)",
           "§9 must keep a markdown LINK to docs/api/error-codes.md — the relocated " <>
             "half of the vocabulary is unreachable from the contract without it."

    assert String.length(relocated_doc()) > 200,
           "docs/api/error-codes.md is empty or stub — the union below would then " <>
             "verdict on §9 alone and the relocation would have laundered 50 codes."
  end

  test "every Content.Errors.known_codes/0 code is documented in §9 or the doc it links to" do
    documented = documented_vocabulary()

    missing =
      Errors.known_codes()
      |> Enum.reject(fn code -> String.contains?(documented, "`#{code}`") end)
      |> Enum.sort()

    assert missing == [],
           "docs/api-v1.md §9 + docs/api/error-codes.md are missing #{length(missing)} " <>
             "error code(s) that Content.Errors.known_codes/0 can emit: " <>
             "#{Enum.join(missing, ", ")}. Add each (with its HTTP status + one-line " <>
             "meaning) to §9, or to the endpoint-specific doc §9 links to, so the " <>
             "served vocabulary and the human contract cannot drift."
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
