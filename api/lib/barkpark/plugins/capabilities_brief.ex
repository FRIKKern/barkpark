defmodule Barkpark.Plugins.CapabilitiesBrief do
  @moduledoc """
  BRIEF-KEEP-LIST v1, server-side (`GET /v1/capabilities?view=brief`,
  task ctx-b2-server-view-brief).

  The ctx-compression charter (`.claude/workflows/bp-ctx-compression-charter.md`,
  decision 6) pins the projection's FIELDS and its ENCODING, because identical
  fields span 2.07–4.47x by encoding alone. The CLI has shipped it since
  wave 1 (`internal/cli/capsbrief.go` `briefManifest/1`), and decision 6 says
  a later server-side `?view=brief` adopts it VERBATIM. This module is that
  adoption: the same top-level keys in the same order, the same legend, and
  the same array-of-tuples command encoding. `capabilities_brief_test.exs`
  holds it to the Go side's committed legend.

      {"manifest_version", "server", "auth_tier", "etag",
       "legend": {"command": [noun, verb, summary, auth_tier, writes, args, flags],
                  "arg":     [name, type, required],
                  "flag":    [name, type]},
       "commands": [[noun, verb, summary, auth_tier, writes,
                     [[name, type, required], …], [[name, type], …]], …]}

  CUT, as in the CLI (recoverable from the default view, never truth-bearing
  for invocation): the nouns catalog, generated_at, and per command http, id,
  mutation_op, set_key, scoped_prefix, default_output, dry_run, batch, source,
  paginated, views, since, arg summaries/`in`, flag summaries/defaults.

  `etag` is the FULL manifest's etag, exactly as the CLI's brief carries it.
  It names the manifest the brief was projected from. The HTTP validator for
  the brief representation is a DIFFERENT string (`http_etag/1`), because
  RFC 9110 §8.8.3 requires two representations of one resource to have
  different strong validators.

  It is a PURE function of the projected manifest. Commands, args and flags
  keep manifest source order, and key order is pinned with
  `Jason.OrderedObject`, so two renders are byte-identical.
  """

  @command_legend ~w(noun verb summary auth_tier writes args flags)
  @arg_legend ~w(name type required)
  @flag_legend ~w(name type)

  @doc "The legend, in tuple order (pinned against the Go brief in tests)."
  def legend, do: %{"command" => @command_legend, "arg" => @arg_legend, "flag" => @flag_legend}

  @doc "Project a (tier-projected) manifest map to BRIEF-KEEP-LIST v1."
  @spec project(map()) :: Jason.OrderedObject.t()
  def project(%{} = manifest) do
    Jason.OrderedObject.new([
      {"manifest_version", manifest["manifest_version"]},
      {"server", server(manifest["server"] || %{})},
      {"auth_tier", manifest["auth_tier"]},
      {"etag", manifest["etag"]},
      {"legend",
       Jason.OrderedObject.new([
         {"command", @command_legend},
         {"arg", @arg_legend},
         {"flag", @flag_legend}
       ])},
      {"commands", Enum.map(manifest["commands"] || [], &command/1)}
    ])
  end

  @doc """
  The HTTP `ETag` for the brief representation of a manifest whose own ETag is
  `full_etag`. It is derived from the full validator, so it changes exactly
  when the projected manifest does, and it can never equal the full
  representation's validator.
  """
  @spec http_etag(String.t()) :: String.t()
  def http_etag(full_etag) when is_binary(full_etag) do
    inner = full_etag |> String.trim_leading("W/") |> String.trim("\"")
    ~s("#{inner}.brief-v1")
  end

  defp command(c) do
    [
      c["noun"],
      c["verb"],
      c["summary"],
      c["auth_tier"],
      c["writes"],
      Enum.map(c["args"] || [], fn a -> [a["name"], a["type"], a["required"]] end),
      Enum.map(c["flags"] || [], fn f -> [f["name"], f["type"]] end)
    ]
  end

  # manifest.Server's field order, with the two `omitempty` pointers
  # (api_version, min_cli) left out when nil, as the Go encoder leaves them out.
  defp server(s) do
    [
      {"name", s["name"]},
      {"version", s["version"]},
      {"base_url", s["base_url"]},
      {"api_version", s["api_version"]},
      {"min_cli", s["min_cli"]}
    ]
    |> Enum.reject(fn {k, v} -> k in ["api_version", "min_cli"] and is_nil(v) end)
    |> Jason.OrderedObject.new()
  end
end
