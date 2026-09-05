defmodule BarkparkCloud.Web.RouterMembersRosterCompletenessTest do
  @moduledoc """
  cch-w45-bl-no-tripwire-on-the-members-roster-completeness-premise — THE
  TRIPWIRE UNDER A CONSOLE PREDICATE'S PREMISE.

  `isSoleOwnerSelf` (cch-w45-s2, cloud/priv/static/app.js) withholds the sole
  owner's OWN "Change role" control by COUNTING OWNERS in the roster the members
  panel is already painting. It is allowed to answer that question — a question
  about the whole team — from a rendered array for exactly one reason:

      GET /v1/teams/:id/members returns the COMPLETE roster. It maps
      `Accounts.list_team_members/1`, which is a bare `Repo.all` with no limit
      and no offset, so what the console holds is the team, not a page of it.

  Until this file that premise lived in WORDS — a comment above the predicate
  and a sentence in the guard's moduledoc — and nothing reddened if `router.ex`
  or `accounts.ex` later added a `limit:` or an `offset:`. The failure that
  buys is specific and nasty: the console starts withholding a control the
  SERVER HONOURS. A second owner exists, sits past the page boundary, the
  predicate counts one owner, and a team owner is told — by omission — that they
  may not change their own role. That is the lie `isSoleOwnerSelf` was built to
  avoid, running backwards.

  TWO ARMS, because neither is sufficient alone:

    * BEHAVIOURAL — a roster larger than any plausible default page comes back
      whole THROUGH THE ROUTE. This is the property the console depends on,
      asserted end-to-end rather than read off the source.
    * STRUCTURAL — the source of `list_team_members/1` and of the route clause
      carries no `limit`/`offset`/pagination at all. The behavioural arm alone
      is defeated by a limit larger than the fixture; this one reds on ANY
      bound, including a generous one, which is the honest shape for a premise
      that says "no limit" rather than "a big limit".

  WHAT NEITHER ARM PROVES: that the console actually renders what the route
  returns. `isSoleOwnerSelf`'s own arms (illegible rows, a missing self row) are
  pinned in the node harness, `__app.test.mjs`. This file holds the SERVER half
  of the contract, which is where the premise is actually decided.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.User
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # Larger than every page size a reasonable author would reach for (10, 20, 25,
  # 50, 100 are the defaults in the libraries this codebase could adopt), and
  # cheap because the members are inserted as bare structs — no password hashing,
  # which is what makes a roster this size a sub-second fixture.
  @roster_size 120

  # The console predicate this file exists to protect. Named as DATA so the two
  # failure messages below cannot drift from each other, and so a reader
  # grepping the console for `isSoleOwnerSelf` lands here.
  @console_predicate "isSoleOwnerSelf (cch-w45-s2, cloud/priv/static/app.js)"

  @premise """
  #{@console_predicate} answers "is this actor PROVABLY the team's only owner?"
  by counting owners in the roster the members panel already holds. That is only
  correct while GET /v1/teams/:id/members is COMPLETE. Bound it and the console
  starts withholding a control the server honours: a second owner past the
  boundary is invisible, the predicate says "sole owner", and a real owner is
  refused their own Change-role button by a client that was wrong.
  """

  defp member_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "roster-#{n}@example.com",
      hashed_password: "not-a-real-hash-this-account-never-signs-in"
    })
  end

  defp source(relative) do
    __DIR__
    |> Path.join("../../../lib/barkpark_cloud/" <> relative)
    |> Path.expand()
    |> File.read!()
  end

  # The lines from `opener` up to the first line that is exactly `end` at the
  # SAME indentation — the function/route body, without the rest of the file.
  # Returns nil when the opener is gone, which the callers treat as a red: a
  # renamed function means this instrument stopped measuring, not that the
  # premise is safe.
  defp block(text, opener) do
    lines = String.split(text, "\n")

    case Enum.find_index(lines, &String.contains?(&1, opener)) do
      nil ->
        nil

      start ->
        indent =
          lines
          |> Enum.at(start)
          |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

        closer = String.duplicate(" ", indent) <> "end"
        rest = Enum.drop(lines, start + 1)

        case Enum.find_index(rest, &(&1 == closer)) do
          nil -> nil
          stop -> [Enum.at(lines, start) | Enum.take(rest, stop)] |> Enum.join("\n")
        end
    end
  end

  # `take`/`drop` are in here because the behavioural arm caught a route-side
  # `Enum.take(25)` this regex originally missed — an Ecto-free bound is exactly
  # as fatal to the premise as a `limit:`, and a source arm that only knows the
  # Ecto spelling would have certified that mutation clean.
  @bounds ~r/\b(limit|offset|first|last|paginate|page|take|drop|slice|chunk)\b/

  test "GET /v1/teams/:id/members returns the COMPLETE roster — #{@roster_size} members, #{@roster_size} rows" do
    owner = member_user()

    {:ok, team} =
      Accounts.create_team(%{
        name: "Big Team",
        slug: "big-team-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Accounts.add_member(team, owner, "owner")

    for _ <- 2..@roster_size, do: {:ok, _} = Accounts.add_member(team, member_user(), "member")

    {:ok, token} = Accounts.create_user_session_token(owner)

    conn =
      conn(:get, "/v1/teams/#{team.id}/members")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(@opts)

    assert conn.status == 200
    members = Jason.decode!(conn.resp_body)["members"]

    assert length(members) == @roster_size,
           """
           The members route returned #{length(members)} of #{@roster_size} members — it is PAGING.

           #{@premise}
           Either restore the complete roster, or make the console stop counting owners in it:
           the predicate and this route are one contract, and it is only ever correct as a pair.
           """

    # Non-vacuity: a roster of the right SIZE built from the wrong rows would
    # pass the count above while proving nothing about completeness.
    assert MapSet.size(MapSet.new(members, & &1["user_id"])) == @roster_size
    assert Enum.count(members, &(&1["role"] == "owner")) == 1
  end

  test "Accounts.list_team_members/1 carries no limit and no offset" do
    body = block(source("accounts.ex"), "def list_team_members(")

    assert body != nil,
           "Accounts.list_team_members/1 was renamed or reshaped, so this arm is measuring " <>
             "nothing. Re-point it at whatever GET /v1/teams/:id/members maps now — do not " <>
             "delete it. #{@premise}"

    refute Regex.match?(@bounds, body),
           """
           Accounts.list_team_members/1 now bounds its read:

           #{body}

           #{@premise}
           If the roster genuinely has to be paged, the console predicate must be retired in the
           same change — it cannot answer a whole-team question from a page.
           """
  end

  test "the GET /v1/teams/:id/members route clause adds no bound of its own" do
    body = block(source("web/router.ex"), ~s(get "/v1/teams/:id/members" do))

    assert body != nil,
           "The GET /v1/teams/:id/members clause was moved or reshaped, so this arm is " <>
             "measuring nothing. Re-point it. #{@premise}"

    refute Regex.match?(@bounds, body),
           """
           The members route clause now bounds the roster itself (the context function is clean,
           so a reader checking only list_team_members/1 would miss this):

           #{body}

           #{@premise}
           """
  end
end
