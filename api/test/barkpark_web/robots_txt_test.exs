defmodule BarkparkWeb.RobotsTxtTest do
  @moduledoc """
  Anonymous-metering charter D6/D15 — `/robots.txt` states the reader's REAL
  policy, and states it where a crawler can read it.

  The file that shipped before this test was the Phoenix generator stub: every
  line a comment, so the effective policy was "crawl everything", including
  `/studio`, `/login`, `/finder`, `/quiz/` and the `/s/` share links. D6's
  ruling is that this file is POLICY, not protection — enforcement is the
  limiter, not a text file a hostile bot ignores — so the value of getting it
  right is that a well-behaved crawler stops spending the reader's budget on
  pages it can never use.

  Two invariants, both of which failed silently before:

    * the endpoint SERVES it (`robots.txt` is in `BarkparkWeb.static_paths/0`,
      which feeds Plug.Static's `only:` in the endpoint) — drop it from that
      list and the request falls through the router to a 404 while the file
      still sits happily on disk, and
    * the BYTES are the D6 shape — asserted against the priv file rather than a
      re-typed literal, because a second copy in a test drifts and pins nothing.

  Shape notes that look like typos and are not: the trailing slashes are
  load-bearing (`/s/` without the slash would also deny `/studio`), there are no
  wildcards (the D6 literal is parser-proven order-insensitive: zero divergence
  between CPython's `urllib.robotparser` and RFC 9309), and there is deliberately
  NO AI-crawler stanza — that stance is a human gate (task
  `am-hg-ai-crawler-stance`), and shipping without one IS the open stance until
  it is decided.

  Plug.Static answers this long before anything touches the database, so this is
  plain ExUnit against the endpoint — no ConnCase, no sandbox.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint BarkparkWeb.Endpoint

  @priv_robots Path.join(:code.priv_dir(:barkpark), "static/robots.txt")

  defp fetch, do: get(build_conn(), "/robots.txt")

  test "GET /robots.txt is served as text/plain with the exact priv bytes" do
    conn = fetch()

    assert conn.status == 200
    assert response_content_type(conn, :txt) =~ "text/plain"
    assert conn.resp_body == File.read!(@priv_robots)
  end

  test "the shipped policy is the D6 shape — real Allows, real Disallows, no stub" do
    body = fetch().resp_body

    assert body =~ "User-agent: *"

    for allow <- ~w(/papers/ /sheets/) do
      assert body =~ "Allow: #{allow}\n",
             "expected an uncommented `Allow: #{allow}` line, got:\n#{body}"
    end

    for disallow <- ~w(/finder /quiz/ /studio /login /s/) do
      assert body =~ "Disallow: #{disallow}\n",
             "expected an uncommented `Disallow: #{disallow}` line, got:\n#{body}"
    end

    # The generator stub commented out its only two directives. A policy that
    # lives entirely inside `#` is the exact regression this slice removes.
    refute body =~ "# User-agent"
    refute body =~ "# Disallow"

    # D6 is the literal shape: no wildcards (`*` outside the user-agent line,
    # `$` anchors) — those are the extension syntax the two parsers disagree on.
    directives = for "Disallow: " <> _ = line <- String.split(body, "\n"), do: line
    refute Enum.any?(directives, &String.contains?(&1, ["*", "$"]))

    # No AI-crawler stanza this wave (human gate am-hg-ai-crawler-stance): the
    # file addresses exactly one user-agent group.
    assert body |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "User-agent:")) == 1
  end
end
