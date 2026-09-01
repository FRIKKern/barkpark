defmodule Barkpark.ConfigForceSslGuardTest do
  @moduledoc """
  task-b2b81f3c1e3bd3ff — `force_ssl` stays out of `api/config/**`.

  Golden Rule #5 / Past Mistake #5 (root `CLAUDE.md`): TLS terminates at the
  reverse proxy (Caddy in prod, the platform edge on the Cloud hosts) and the
  app speaks plain HTTP behind it. Phoenix therefore only ever sees `http` on
  the wire, so `force_ssl` 301-redirects to https, the proxy re-forwards as
  http, and the request loops forever — the recorded outage in which every API
  call returned empty.

  Two assertions, and they are NOT the same strength:

    * **The bare `force_ssl: [hsts: true]` form must not appear anywhere in
      `config/`, comment or code.** This is the RED-before assertion: before
      this test landed, `config/runtime.exs` carried exactly that string in the
      stock Phoenix "## SSL Support" boilerplate, recommending the one shape
      that guarantees the loop (no `rewrite_on:`, so a proxied request is always
      read as plaintext) *and* pins browsers to https for a year while it loops.
      A comment is enough to fail: the boilerplate's whole failure mode was that
      it read as sanctioned advice sitting 250 lines below the correct guidance
      in the same file.

    * **No live (uncommented) line may set `force_ssl:`.** A standing guard —
      it already held when this test was written, and exists so re-enabling
      `force_ssl` cannot land silently.

  The commented `force_ssl: [rewrite_on: [:x_forwarded_proto]]` block that
  `config/prod.exs` carries is deliberately allowed: it is the only safe form
  (it trusts the proxy's `X-Forwarded-Proto`) and is the documented recipe for
  the day TLS terminates at the app tier.
  """
  use ExUnit.Case, async: true

  @config_dir Path.expand("../../config", __DIR__)

  defp config_files do
    files = Path.wildcard(Path.join(@config_dir, "*.exs"))

    # Non-vacuity: if the glob ever stops resolving (moved dir, renamed files)
    # every assertion below would pass over an empty list.
    assert length(files) >= 3,
           "expected the config/*.exs corpus, found #{inspect(files)} under #{@config_dir}"

    assert Enum.any?(files, &(Path.basename(&1) == "runtime.exs")),
           "config/runtime.exs missing from #{inspect(Enum.map(files, &Path.basename/1))}"

    files
  end

  test "no config file carries the bare `force_ssl: [hsts: true]` boilerplate" do
    offenders =
      for path <- config_files(),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.contains?(line, "force_ssl: [hsts: true]"),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           `force_ssl: [hsts: true]` must not appear in api/config/** — not even
           in a comment. Without `rewrite_on: [:x_forwarded_proto]` it 301-loops
           behind the TLS-terminating proxy (Golden Rule #5 / Past Mistake #5)
           and its HSTS header pins browsers to https for a year mid-loop.

           The only safe form, already commented in config/prod.exs, is:
               force_ssl: [rewrite_on: [:x_forwarded_proto]]

           Offending lines:
           #{Enum.join(offenders, "\n")}
           """
  end

  test "no config file sets force_ssl in live (uncommented) code" do
    offenders =
      for path <- config_files(),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          # Strip any trailing comment, then look for a live `force_ssl:` set.
          code = line |> String.split("#", parts: 2) |> hd(),
          String.contains?(code, "force_ssl"),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           force_ssl is DELIBERATELY off (Golden Rule #5 / Past Mistake #5): TLS
           terminates at the reverse proxy and the app tier has no HTTPS
           listener, so enabling it 301-loops every request.

           Do not re-enable without a real app-tier HTTPS listener; when that
           day comes the form is `force_ssl: [rewrite_on: [:x_forwarded_proto]]`
           (see docs/ops/adding-a-domain.md).

           Offending lines:
           #{Enum.join(offenders, "\n")}
           """
  end
end
