defmodule BarkparkWeb.CapabilitiesViewBriefTest do
  @moduledoc """
  `GET /v1/capabilities?view=brief` (ctx-b2-server-view-brief): the server-side
  adoption of BRIEF-KEEP-LIST v1, the CLI's born-brief projection
  (`internal/cli/capsbrief.go`), verbatim.

    * OPT-IN: without `?view=brief` the body and ETag are byte-identical to the
      default, and `?view=full` is the default spelled out. Released bp
      binaries strict-decode the default body.
    * VERBATIM: the legend is read out of the Go source, so the two
      implementations cannot drift apart silently. Top-level key order and
      tuple shapes match the Go `briefDoc`, and every tuple is the
      projection of the full manifest's command at the same index.
    * RFC 9110 §8.8.3: the brief and the full body are two representations,
      so they carry DIFFERENT strong validators. Each one's ETag revalidates
      only itself, `Vary: authorization` rides both, and the brief body's own
      `etag` names the full manifest it was projected from (as the CLI's
      brief does).
    * an unknown view is a 400 naming the two that exist.
  """
  use BarkparkWeb.ConnCase, async: true

  @go_source Path.expand("../../../../internal/cli/capsbrief.go", __DIR__)

  defp caps(conn, query, headers \\ []) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> get("/v1/capabilities" <> query)
  end

  defp etag(resp), do: resp |> get_resp_header("etag") |> List.first()

  # The legend as the Go brief declares it, read from the source, not retyped.
  defp go_legend do
    src = File.read!(@go_source)

    for key <- ~w(Command Arg Flag), into: %{} do
      [_, list] = Regex.run(~r/\b#{key}:\s*\[\]string\{([^}]*)\}/, src)

      {String.downcase(key),
       Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first) |> List.flatten()}
    end
  end

  test "opt-in: no view and view=full serve the identical default body and ETag", %{conn: conn} do
    plain = caps(conn, "")
    full = caps(build_conn(), "?view=full")

    assert plain.status == 200 and full.status == 200
    # `generated_at` is the request's clock, the one key that differs between
    # any two fetches; everything else, and the content-addressed ETag, match.
    strip = fn r -> r.resp_body |> Jason.decode!() |> Map.delete("generated_at") end
    assert strip.(plain) == strip.(full)
    assert etag(plain) == etag(full)
    refute Map.has_key?(Jason.decode!(plain.resp_body), "legend")
  end

  test "the brief is BRIEF-KEEP-LIST v1: Go's legend, Go's key order, Go's tuples", %{conn: conn} do
    full = Jason.decode!(caps(conn, "").resp_body)
    resp = caps(build_conn(), "?view=brief")
    assert resp.status == 200
    brief = Jason.decode!(resp.resp_body)

    # The legend is the Go source's, read mechanically.
    assert go_legend() == %{
             "command" => ~w(noun verb summary auth_tier writes args flags),
             "arg" => ~w(name type required),
             "flag" => ~w(name type)
           },
           "the Go brief's legend moved; BRIEF-KEEP-LIST v1 is pinned on both sides"

    assert brief["legend"] == go_legend()

    # Top-level key ORDER is part of the encoding (Go's briefDoc field order).
    ordered = Jason.decode!(resp.resp_body, objects: :ordered_objects)

    assert Enum.map(ordered.values, &elem(&1, 0)) ==
             ~w(manifest_version server auth_tier etag legend commands)

    assert String.starts_with?(resp.resp_body, ~s({"manifest_version":))
    refute Map.has_key?(brief, "nouns")
    refute Map.has_key?(brief, "generated_at")

    assert brief["manifest_version"] == full["manifest_version"]
    assert brief["auth_tier"] == full["auth_tier"]
    assert brief["etag"] == full["etag"]

    # Every tuple is the projection of the full manifest's command at the same
    # index. Source order is kept, nothing is sorted or dropped.
    assert length(brief["commands"]) == length(full["commands"])
    assert length(full["commands"]) > 0

    for {tuple, c} <- Enum.zip(brief["commands"], full["commands"]) do
      assert tuple == [
               c["noun"],
               c["verb"],
               c["summary"],
               c["auth_tier"],
               c["writes"],
               Enum.map(c["args"] || [], &[&1["name"], &1["type"], &1["required"]]),
               Enum.map(c["flags"] || [], &[&1["name"], &1["type"]])
             ]
    end

    # It is a brief: the cut fields are gone, so the body is markedly smaller.
    assert byte_size(resp.resp_body) < byte_size(Jason.encode!(full)) * 0.6
  end

  test "RFC 9110: brief and full carry different validators, and each revalidates only itself",
       %{conn: conn} do
    full = caps(conn, "")
    brief = caps(build_conn(), "?view=brief")
    full_tag = etag(full)
    brief_tag = etag(brief)

    assert is_binary(full_tag) and is_binary(brief_tag)
    refute full_tag == brief_tag

    # The full body's ETag must NOT revalidate the brief request, nor vice versa.
    assert caps(build_conn(), "?view=brief", [{"if-none-match", full_tag}]).status == 200
    assert caps(build_conn(), "", [{"if-none-match", brief_tag}]).status == 200

    # Each one's own ETag does.
    assert caps(build_conn(), "?view=brief", [{"if-none-match", brief_tag}]).status == 304
    assert caps(build_conn(), "", [{"if-none-match", full_tag}]).status == 304

    # Both are a function of the Authorization header.
    for resp <- [full, brief] do
      vary = resp |> get_resp_header("vary") |> Enum.join(",") |> String.downcase()
      assert vary =~ "authorization"
    end
  end

  test "an unknown view is a 400 naming the two that exist", %{conn: conn} do
    resp = caps(conn, "?view=tiny")
    assert resp.status == 400
    assert resp.resp_body =~ "view=brief"
    assert resp.resp_body =~ "tiny"
  end
end
