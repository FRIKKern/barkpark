defmodule BarkparkWeb.Contract.ErrorEnvelopeShapeTest do
  @moduledoc """
  §9 of docs/api-v1.md states the whole error contract in one line:

      All errors: {"error":{"code","message","request_id"}}

  `BarkparkWeb.ErrorResponse` is the one emitter that produces it, and
  `error_code_coverage_test.exs` already guards that every code reaching the
  wire is a DECLARED code. But that guard scans for `code:` string literals —
  so it is structurally blind to the two shapes that carry no `code` at all:

    * a BARE STRING body, `json(%{error: "state mismatch"})` — no code, no
      message, no request_id. Twenty-one such sites lived in the SSO callback
      controllers (social/oidc/saml), the exact boundary where correlating a
      user's failure to a log line matters most.
    * a body keyed on `type:` instead of `code:`, `%{error: %{type:
      "xsd_invalid", …}}` — a client switching on `error.code` reads
      `undefined`, and the coverage guard never counted the code either. The
      ONIX export controller carried two.

  Neither shape could fail any existing test. This guard closes both, so the
  class cannot regrow: it reads the same emitter directories the coverage guard
  reads, and refuses a hand-built error body that is a bare string or is keyed
  on a discriminator other than `code`.

  It does NOT forbid hand-built `%{error: %{code: …}}` maps — 90-odd of those
  still exist and several of them stamp `request_id` themselves. Narrowing that
  population is separate work; this guard only fences the two shapes that can
  never be right.
  """
  use ExUnit.Case, async: true

  @emitter_globs [
    "lib/barkpark_web/controllers/**/*.ex",
    "lib/barkpark_web/plugs/**/*.ex",
    "lib/barkpark_web/endpoint.ex",
    "lib/barkpark/plugins/**/web/**/*.ex"
  ]

  # `json(%{error: "…"})` — an error body that is a bare string.
  @bare_string_re ~r/json\(\s*%\{\s*error:\s*"/
  # `error: %{type: "…"` — an error object discriminated by `type`, not `code`.
  # The `\s*` spans the newline of the multi-line form the ONIX controller used.
  @type_keyed_re ~r/error:\s*%\{\s*type:\s*"/

  defp emitter_files do
    @emitter_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq()
  end

  defp offenders(regex) do
    for path <- emitter_files(),
        body = File.read!(path),
        Regex.match?(regex, body),
        do: path
  end

  test "the emitter globs match a real population" do
    assert length(emitter_files()) > 40,
           "emitter globs matched too few files — a path moved and this guard went blind"
  end

  test "the regexes actually match the shapes they are written for" do
    # A guard whose pattern no longer matches anything passes vacuously over a
    # repo full of violations. Pin both patterns against synthetic offenders.
    assert Regex.match?(@bare_string_re, ~S[json(%{error: "state mismatch"})])
    assert Regex.match?(@type_keyed_re, ~S[json(%{error: %{type: "xsd_invalid"}})])

    assert Regex.match?(
             @type_keyed_re,
             ~S[json(%{
               error: %{
                 type: "not_found"
               }
             })]
           )

    # …and confirm they do NOT match the canonical shape.
    refute Regex.match?(@bare_string_re, ~S[json(%{error: %{code: "not_found"}})])
    refute Regex.match?(@type_keyed_re, ~S[json(%{error: %{code: "not_found"}})])
  end

  test "no emitter writes a bare-string error body" do
    assert offenders(@bare_string_re) == [],
           """
           These files answer with `%{error: "<string>"}` — no code, no message,
           no request_id, and nothing a client can branch on:

             #{Enum.join(offenders(@bare_string_re), "\n  ")}

           Emit through BarkparkWeb.ErrorResponse.emit/3 or emit_custom/5 so the
           body carries the §9 shape and the request_id Plug.RequestId already
           stamped on the conn.
           """
  end

  test "no emitter keys an error object on `type` instead of `code`" do
    assert offenders(@type_keyed_re) == [],
           """
           These files answer with `%{error: %{type: …}}`. §9 names the
           discriminator `code`; a client switching on `error.code` reads
           undefined, and error_code_coverage_test cannot see the code at all:

             #{Enum.join(offenders(@type_keyed_re), "\n  ")}

           Rename the key to `code` and emit through BarkparkWeb.ErrorResponse,
           then declare the code in Content.Errors (@public_inline_codes) or, for
           an operational endpoint, in error_code_coverage_test's @offspec_codes.
           """
  end
end
