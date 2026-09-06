defmodule BarkparkCloud.Web.RouterSiteDomainFormatLegalCapTest do
  @moduledoc """
  cch-w23-bl-site-domains-cruel-family — THE CRUELTY LEDGER'S `site.domains`
  GENERATOR, PROVEN AGAINST THE SERVER RATHER THAN ASSUMED.

  `site.domains` is the cruelty ledger's best member-reachable family, and it
  carries a trap that files a FALSE refusal on it. Its cap is NOT a
  `validate_length` — `Site.changeset/2` runs `validate_domains/1`, a
  `validate_change` that requires BOTH `String.length(d) <= 253` AND a match
  against `@domain_format` (`^label(\\.label)+$`, each label at most 63 octets).
  So:

    * a `String.duplicate("q", 253)` — or any single long label, e.g. the
      212-character one a length-only generator sized to bite the widest driven
      viewport — is refused 422 by the FORMAT half, and a builder measuring only
      that records NONE-POSSIBLE on a family that is in fact reachable;
    * the ADMISSIBLE MAXIMUM is a CONSTRUCTION: `63 + "." + 63 + "." + 63 + "."
      + 61 = exactly 253`, which the server accepts with 200 and persists as a
      one-element array whose only member is 253 characters long;
    * 254 — the same shape with a 62-character tail — is refused 422.

  All three are DRIVEN here, through the real router, by a plain team MEMBER.

  THE LABELS ARE READ OFF THE COMMITTED FIXTURE, NEVER TRANSCRIBED.
  `cloud/priv/static/__preview__/scenarios.mjs` holds `CRUEL_SITE_DOMAIN`, the
  string the console's overflow-guard cruelty ledger drives at `.site-host`.
  This test parses those bytes and posts THAT value — so a retune of the fixture
  that quietly makes it server-ILLEGAL (or merely comfortable) reds here, and
  the ledger's admissible field and the server's answer cannot drift apart.

  MEMBER-REACHABILITY IS MEASURED, NOT INHERITED. The poster below is joined to
  the team at role `"member"`. `post "/v1/sites/:id/domains"` calls the 2-arity
  `with_team_site(conn, fun)`, which delegates to `with_team_site(conn, :session,
  fun)`, whose `:session` branch is a bare `Auth.require_user(conn, [])` — no
  `{:ability, "write"}`, no role gate. A 200 for a member is that fact, driven.

  THE APPEND-ORDER REFUSAL, DRIVEN TOO. `Registry.add_site_domain/2` writes
  `Enum.uniq(existing ++ [norm])`, so the cruel value lands LAST. Both console
  row builders paint `domains[0]` only, so the cruel domain is list-visible only
  on a site that was DOMAINLESS when the member pushed. Both post-states are
  asserted below: the domainless site ends `[cruel]` (index 0, visible), and the
  site that already answered on `acme.com` ends `["acme.com", cruel]` (index 1,
  invisible to every list renderer in the console).
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The committed console fixture, read as BYTES. Resolved off this file rather
  # than off cwd so the test does not depend on where mix was launched.
  @scenarios_mjs Path.expand(
                   "../../../priv/static/__preview__/scenarios.mjs",
                   __DIR__
                 )

  ## ── the fixture parser ────────────────────────────────────────────────────
  ##
  ## scenarios.mjs is ESM; ExUnit cannot import it. It CAN read it, and the two
  ## constants are committed in a shape a regex can bound exactly:
  ##
  ##   const CRUEL_SITE_SLUG = atLength("site slug",
  ##     "acmecorporate…node01", 63);
  ##   const CRUEL_SITE_DOMAIN = atLength("site domain", [
  ##     CRUEL_SITE_SLUG,
  ##     "…", "…", "…",
  ##   ].join("."), 253);
  ##
  ## Every arm below refuses loudly rather than falling back to a transcribed
  ## literal: a parser that silently returns a hand-typed string would make this
  ## whole file assert against itself instead of against the fixture.
  defp fixture_labels do
    src = File.read!(@scenarios_mjs)

    slug =
      case Regex.run(
             ~r/const CRUEL_SITE_SLUG = atLength\(\s*"site slug",\s*"([a-z0-9-]+)",\s*63\s*\)/s,
             src
           ) do
        [_, s] ->
          s

        nil ->
          flunk(
            "scenarios.mjs no longer spells `const CRUEL_SITE_SLUG = atLength(\"site slug\", \"…\", 63)` — " <>
              "this parser has nothing to read, and a fallback literal here would make the test assert against itself"
          )
      end

    block =
      case Regex.run(
             ~r/const CRUEL_SITE_DOMAIN = atLength\(\s*"site domain",\s*\[(.*?)\]\.join\("\."\),\s*253\s*\)/s,
             src
           ) do
        [_, b] ->
          b

        nil ->
          flunk(
            "scenarios.mjs no longer spells `const CRUEL_SITE_DOMAIN = atLength(\"site domain\", [ … ].join(\".\"), 253)` — " <>
              "the ledger's admissible construction has moved and this test can no longer read it"
          )
      end

    labels =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.trim_trailing(&1, ","))
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "//")))
      |> Enum.map(fn
        "CRUEL_SITE_SLUG" -> slug
        <<?", rest::binary>> -> String.trim_trailing(rest, "\"")
        other -> flunk("unparsed member of the CRUEL_SITE_DOMAIN array: #{inspect(other)}")
      end)

    # NON-VACUITY. A parse that returned one label would still `join(".")` into
    # a string, and a single-label host is refused by @domain_format — so the
    # 422 arms below would pass for the wrong reason.
    assert length(labels) >= 2,
           "parsed #{length(labels)} label(s) from CRUEL_SITE_DOMAIN — the format needs at least two, " <>
             "and a one-label parse would make the 422 arms green for the parser's reason instead of the server's"

    labels
  end

  defp cruel_domain, do: Enum.join(fixture_labels(), ".")

  ## ── fixtures ──────────────────────────────────────────────────────────────

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  # An OWNER and a plain MEMBER on the same team. The member is the one who
  # drives every POST below — the reachability half of the ledger row.
  defp team_with_member do
    owner = user_fixture()
    member = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, owner, "owner")
    {:ok, membership} = Accounts.add_member(team, member, "member")

    assert membership.role == "member",
           "the poster must NOT be an owner or this proves nothing about role gating"

    {team, member}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A site that is DOMAINLESS at rest — the only shape on which an appended
  # cruel domain is list-visible.
  defp domainless_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, Enum.into(attrs, %{name: "Site #{n}", slug: "site-#{n}"}))

    assert site.domains == [], "the fixture site must start domainless"
    site
  end

  ## ── the construction, before any HTTP ─────────────────────────────────────

  describe "the committed fixture IS the admissible maximum" do
    test "CRUEL_SITE_DOMAIN is 253 chars as 4 labels, none over the 63-octet DNS ceiling" do
      labels = fixture_labels()

      assert Enum.map(labels, &String.length/1) == [63, 63, 63, 61],
             "the ledger's admissible construction is 3 x 63 + a 61 tail; scenarios.mjs now reads " <>
               inspect(Enum.map(labels, &String.length/1))

      assert String.length(cruel_domain()) == 253
      # 3 x 63 + 3 separators + 61 — the arithmetic spelled out, so a reader can
      # check the number instead of trusting it.
      assert 63 + 1 + 63 + 1 + 63 + 1 + 61 == 253
    end
  end

  ## ── the drive ─────────────────────────────────────────────────────────────

  describe "POST /v1/sites/:id/domains at the cap, driven by a plain MEMBER" do
    test "the 253-char FORMAT-LEGAL construction → 200, persisting as a [253] array" do
      {team, member} = team_with_member()
      bp = barkpark_fixture(team)
      site = domainless_site(bp)
      token = login_token(member)
      domain = cruel_domain()

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: domain}, token)

      assert conn.status == 200,
             "a plain member was refused #{conn.status} — with_team_site/2's :session branch is a bare " <>
               "Auth.require_user with no role gate, so this family is member-reachable: #{conn.resp_body}"

      domains = json_body(conn)["site"]["domains"]
      assert domains == [domain]
      assert Enum.map(domains, &String.length/1) == [253]

      # And it is at REST, not merely in the response envelope.
      assert Repo.get!(Registry.Site, site.id).domains == [domain]
    end

    test "254 — the same shape with a 62-char tail — → 422" do
      {team, member} = team_with_member()
      bp = barkpark_fixture(team)
      site = domainless_site(bp)
      token = login_token(member)

      labels = fixture_labels()
      {head, [tail]} = Enum.split(labels, length(labels) - 1)
      over = Enum.join(head ++ [tail <> "x"], ".")

      assert String.length(over) == 254
      # The refusal must be about LENGTH, not shape: every label is still legal.
      assert Enum.all?(String.split(over, "."), &(String.length(&1) <= 63))

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: over}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
      assert Repo.get!(Registry.Site, site.id).domains == []
    end

    test "THE TRAP: a 212-char single label → 422, so a length-only generator files a FALSE NONE-POSSIBLE" do
      {team, member} = team_with_member()
      bp = barkpark_fixture(team)
      site = domainless_site(bp)
      token = login_token(member)

      # What a length-only generator emits: one unbroken token, comfortably
      # UNDER the 253 length cap, and refused anyway — @domain_format's `(\.…)+`
      # makes at least one dot mandatory and caps every label at 63 octets.
      naive = String.duplicate("q", 212)
      assert String.length(naive) < 253
      refute String.contains?(naive, ".")

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: naive}, token)

      assert conn.status == 422,
             "the naive generator was ACCEPTED — the trap this row exists for has moved and the " <>
               "FORMAT-LEGAL classification needs re-deriving"

      assert Repo.get!(Registry.Site, site.id).domains == []

      # THE PAIR IS THE POINT: the same member, the same site, the same length
      # class — one refused for its SHAPE, one accepted at the true maximum.
      ok = call(:post, "/v1/sites/#{site.id}/domains", %{domain: cruel_domain()}, token)
      assert ok.status == 200
      assert Enum.map(json_body(ok)["site"]["domains"], &String.length/1) == [253]
    end
  end

  ## ── the append-order refusal, as a measurement ────────────────────────────

  describe "add_site_domain/2 appends, which is why the console fixture is domainless" do
    test "a site that already answers on acme.com puts the cruel domain at index 1, invisible to a domains[0] renderer" do
      {team, member} = team_with_member()
      bp = barkpark_fixture(team)
      site = domainless_site(bp)
      token = login_token(member)

      first = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "acme.example.com"}, token)
      assert first.status == 200

      second = call(:post, "/v1/sites/#{site.id}/domains", %{domain: cruel_domain()}, token)
      assert second.status == 200

      domains = json_body(second)["site"]["domains"]

      assert domains == ["acme.example.com", cruel_domain()],
             "add_site_domain/2 is `Enum.uniq(existing ++ [norm])` — the cruel value lands LAST"

      # The console consequence, stated as the assertion it is: every site-row
      # builder paints `(s.domains && s.domains[0])`, so on THIS site the cruel
      # value never reaches the page. The cruelty-ledger fixture therefore
      # carries the cruel domain ALONE.
      assert String.length(hd(domains)) == 16
      assert String.length(List.last(domains)) == 253
    end
  end
end
