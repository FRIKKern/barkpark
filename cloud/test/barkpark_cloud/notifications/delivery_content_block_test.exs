defmodule BarkparkCloud.Notifications.DeliveryContentBlockTest do
  @moduledoc """
  dr-w29 — A RECEIPT MUST BE ABLE TO SAY WHAT IT SAID, not only to settle a
  dispute about it.

  dr-w34 (`content_sha256`) gave the row a FINGERPRINT. A fingerprint answers
  "is this the body?" and can never answer "what did it say?" to a reader who
  does not already hold a candidate render — so "the digest said X" was still
  unprovable by anyone who had not kept X. This slice stores the two narrowest
  things that answer it directly: the rendered SUBJECT, verbatim, and the
  NUMERIC BLOCK parsed back out of that subject.

  ## What each section holds, and why it is not the weak version of itself

    * §1 — the stored subject and counts are compared against THE FIXTURE THIS
      FILE BUILT, not against a re-run of the parser that wrote them. The test
      knows it registered two current boxes, one behind box and one paused box;
      it asserts the row says exactly that. A column filled by a circular
      re-read of the writer's own arithmetic passes a parser-vs-parser check and
      fails this one. The row is then read back by RAW SQL, because a value that
      only exists on an Ecto struct never reached Postgres.
    * §2 — the CONTROL on the shape: a fleet with a DIVERGED box renders a
      subject with a `diverged` segment, and the stored map must GROW that key.
      A stored block copied off `DigestEmail.summary/2`'s map instead of read
      back out of the render would carry `diverged` on every row, including the
      ones whose subject never printed it.
    * §3 — the RENDER-TRACKS arm dr-w29 c2 asks for by name: the same summary
      mutated by ONE count renders a different subject and yields a different
      stored block, and the unmutated render still yields the original — so the
      inequality is the mutation losing, not the comparison never winning.
    * §4 — the QUIET arm: a real send on the same rail that does NOT hand its
      message to the receipt leaves both columns NULL and says so in words.
    * §5 — the RETENTION FENCES, as behaviour rather than as prose: an
      over-limit subject is stored VERBATIM-OR-NOT-AT-ALL, and `changeset/2`
      REFUSES a count map carrying a key outside the closed vocabulary or a
      value that is not an integer. This is what stops the column becoming a
      body sink by a future writer's forgetfulness.
    * §6 — TENANCY FROM THE LOW-PRIVILEGE SIDE. A team's stored subject is now
      readable prose on a row, so the fence has to be proved by a principal who
      should lose: an owner of team B, naming team A's id, reads zero of team
      A's rows through `/v1/notifications/deliveries`, while team A's own owner
      reads them. Both halves, or the refusal could be a route that returns
      nothing to anybody.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.DigestEmail
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct horse staple"

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u
  end

  defp team(user) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  defp instance(team, name, slug, attrs) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: name, slug: slug})

    bp
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp digest_rows do
    Delivery
    |> where([d], d.event == "fleet_digest")
    |> Repo.all()
  end

  # The row as POSTGRES holds it, not as the writer's schema hands it back.
  # `content_counts` is read as TEXT and decoded here so the assertion is about
  # the jsonb document on disk and not about Postgrex's typed decode agreeing
  # with Ecto's.
  defp stored_block(id) do
    %{rows: [[subject, counts_json]]} =
      Repo.query!(
        "SELECT content_subject, content_counts::text FROM notification_deliveries WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    {subject, counts_json && Jason.decode!(counts_json)}
  end

  ## 1. THE ROW SAYS WHAT THE FIXTURE BUILT.

  test "a real digest send stores the rendered subject verbatim and its numeric block" do
    n = System.unique_integer([:positive])
    owner = user("op-#{n}@example.com")
    t = team(owner)

    # TWO current, ONE behind, ONE of the current ones paused. These rungs are
    # the test's OWN knowledge — the assertions below are against this fixture,
    # never against a second run of the writer's parser.
    a = instance(t, "A", "a-#{n}", %{commit_ancestry: "current"})
    b = instance(t, "B", "b-#{n}", %{commit_ancestry: "current", autoupdate_paused: true})
    c = instance(t, "C", "c-#{n}", %{commit_ancestry: "behind"})

    assert {:ok, %{sent: 1, recipients: [recipient]}} =
             Notifications.deliver_fleet_digest([a, b, c])

    # The struct the TRANSPORT received, out of the Test adapter — not a second
    # rendering of the same summary.
    assert_receive {:email, %Swoosh.Email{} = delivered}
    assert [row] = digest_rows()
    assert row.recipient == recipient

    # VERBATIM. Not "contains", not "starts with": the stored string is the
    # subject the transport was handed, byte for byte.
    assert row.content_subject == delivered.subject

    # And the fixture's own arithmetic, stated independently of the parser:
    # 2 current, 1 behind, 0 unmeasured, 1 paused — and NO `diverged` /
    # `ahead_of_main` keys, because the render omits those segments at zero.
    assert row.content_counts == %{
             "current" => 2,
             "behind" => 1,
             "unmeasured" => 0,
             "paused" => 1
           }

    # The subject a human read really does say it, so the map above is a
    # description of the render rather than of the summary behind it.
    assert row.content_subject =~ "2 current"
    assert row.content_subject =~ "1 behind"
    assert row.content_subject =~ "1 paused"
    refute row.content_subject =~ "diverged"

    # IN POSTGRES, which is the whole point of a receipt that outlives the
    # container that wrote it.
    {stored_subject, stored_counts} = stored_block(row.id)
    assert stored_subject == delivered.subject
    assert stored_counts == row.content_counts
  end

  ## 2. THE CONTROL ON SHAPE — a rung the render prints appears; one it omits does not.

  test "a diverged box makes the render print a diverged segment and the row GROW that key" do
    n = System.unique_integer([:positive])
    owner = user("op-d-#{n}@example.com")
    t = team(owner)

    a = instance(t, "A", "a-#{n}", %{commit_ancestry: "current"})
    d = instance(t, "D", "d-#{n}", %{commit_ancestry: "diverged"})

    assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([a, d])
    assert_receive {:email, %Swoosh.Email{} = delivered}
    assert [row] = digest_rows()

    assert delivered.subject =~ "1 diverged"

    assert row.content_counts == %{
             "current" => 1,
             "behind" => 0,
             "diverged" => 1,
             "unmeasured" => 0,
             "paused" => 0
           }

    # The §1 fleet had no diverged box and its row carried NO such key. A block
    # taken off the summary map rather than read back out of the render would
    # carry `diverged: 0` in both cases and could not tell these two rows apart.
    assert Map.has_key?(row.content_counts, "diverged")
  end

  ## 3. THE VALUE TRACKS THE RENDER (dr-w29 c2).

  test "changing the render changes the stored value; the unchanged render does not" do
    base = %{
      total: 3,
      current: 2,
      behind: 1,
      diverged: 0,
      ahead: 0,
      unmeasured: 0,
      paused: 0,
      latest: "v1.2.3",
      instances: []
    }

    email = DigestEmail.build(base, "ops@example.com")
    counts = Delivery.content_counts(email)
    assert counts == %{"current" => 2, "behind" => 1, "unmeasured" => 0, "paused" => 0}

    # ONE count moved. The renderer prints a different subject, so the stored
    # value must be different — this is the mutation dr-w29 c2 asks to see lose.
    moved = DigestEmail.build(%{base | current: 1, behind: 2}, "ops@example.com")
    assert moved.subject != email.subject

    assert Delivery.content_counts(moved) == %{
             "current" => 1,
             "behind" => 2,
             "unmeasured" => 0,
             "paused" => 0
           }

    refute Delivery.content_counts(moved) == counts

    # And the subject is carried verbatim, so a render change is visible in BOTH
    # stored columns and not only in the derived one.
    assert Delivery.content_subject(moved) == moved.subject
    assert Delivery.content_subject(moved) != Delivery.content_subject(email)

    # The QUIET half: re-rendering the SAME summary yields the SAME stored
    # values, so the inequality above is a property of the content and not of
    # the clock, the address or the row.
    again = DigestEmail.build(base, "someone-else@example.com")
    assert Delivery.content_subject(again) == Delivery.content_subject(email)
    assert Delivery.content_counts(again) == counts
  end

  ## 4. THE QUIET ARM — a send the receipt never saw stores nothing and says so.

  test "a send recorded without the rendered message leaves both columns NULL and says why" do
    n = System.unique_integer([:positive])
    owner = user("member-#{n}@example.com")
    t = team(owner)

    assert {:ok, _} = Notifications.deliver_test(t)

    assert [row] =
             Delivery
             |> where([d], d.event == "test")
             |> Repo.all()

    assert row.content_subject == nil
    assert row.content_counts == nil

    {stored_subject, stored_counts} = stored_block(row.id)
    assert stored_subject == nil
    assert stored_counts == nil

    assert Delivery.content_block_meaning(nil, nil) =~ "cannot be read from this row"

    # And the stored-content sentence is a DIFFERENT sentence, or a reader that
    # renders one for both states is back to a blank caveat.
    said =
      Delivery.content_block_meaning("Your Barkpark instances — 1 current", %{"current" => 1})

    assert said =~ "stored verbatim"
    assert said =~ "body itself is not stored"
    refute said =~ "cannot be read from this row"

    # A non-email argument never yields either column.
    assert Delivery.content_subject(nil) == nil
    assert Delivery.content_counts("0 current") == nil
    assert Delivery.content_counts(%{subject: "0 current"}) == nil

    # A subject with no count this vocabulary knows yields `nil`, not `%{}` —
    # "stated no block" and "stated an empty block" are different facts.
    assert Delivery.content_counts(%Swoosh.Email{subject: "Reset your password"}) == nil
  end

  ## 5. THE RETENTION FENCES, AS BEHAVIOUR.

  test "an over-limit subject is stored verbatim-or-not-at-all, never truncated" do
    limit = Delivery.subject_retention_limit()

    at_limit = String.duplicate("s", limit)
    assert Delivery.content_subject(%Swoosh.Email{subject: at_limit}) == at_limit

    over = String.duplicate("s", limit + 1)
    # NOT a prefix of it. A truncated sentence reads as a complete one.
    assert Delivery.content_subject(%Swoosh.Email{subject: over}) == nil
  end

  test "changeset/2 REFUSES a count map outside the closed integer vocabulary" do
    base = %{recipient: "ops@example.com", event: "fleet_digest"}

    ok = Delivery.changeset(%Delivery{}, Map.put(base, :content_counts, %{"current" => 2}))
    assert ok.valid?

    # A PROSE key — the exact way this column would become a body sink.
    prose =
      Delivery.changeset(
        %Delivery{},
        Map.put(base, :content_counts, %{"body" => "the site prod-1 is behind"})
      )

    refute prose.valid?
    assert {_msg, _} = prose.errors[:content_counts]

    # A non-integer value under a LEGAL key loses too, so the refusal is about
    # the value space and not only about the key space.
    stringy =
      Delivery.changeset(%Delivery{}, Map.put(base, :content_counts, %{"current" => "two"}))

    refute stringy.valid?

    # NULL is always allowed — it is the honest value for an unmeasured send.
    assert Delivery.changeset(%Delivery{}, base).valid?

    # And the ruling is a function a test can quote, not a sentence in a PR body.
    ruling = Delivery.content_retention_ruling()
    assert ruling =~ "NOT retained: the body"
    assert ruling =~ "cross-team"
  end

  ## 6. THE FENCE FROM THE LOW-PRIVILEGE SIDE.

  test "an outsider cannot read another team's stored subject through the delivery log" do
    n = System.unique_integer([:positive])
    owner_a = user("a-owner-#{n}@example.com")
    owner_b = user("b-owner-#{n}@example.com")
    team_a = team(owner_a)
    team_b = team(owner_b)

    a = instance(team_a, "A", "a-#{n}", %{commit_ancestry: "behind"})
    assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([a])
    assert [row] = digest_rows()
    assert row.team_id == team_a.id
    assert is_binary(row.content_subject)

    {:ok, token_a} = Accounts.create_user_session_token(owner_a)
    {:ok, token_b} = Accounts.create_user_session_token(owner_b)

    # TEAM A'S OWN OWNER READS IT. Without this half, the refusal below could be
    # a route that returns nothing to anybody.
    mine = deliveries(token_a)
    assert [served] = mine
    assert served["content_subject"] == row.content_subject
    assert served["content_counts"] == row.content_counts
    assert served["content_block_meaning"] =~ "stored verbatim"

    # THE OUTSIDER. `owner_b` is an owner — of team B — and team A's id
    # (#{team_a.id} at runtime) appears nowhere in what they are served. The
    # route resolves the caller's OWN team; there is no team parameter to point
    # at another one, and the stored prose is fenced by exactly that.
    theirs = deliveries(token_b)
    assert theirs == []
    refute Enum.any?(theirs, &(&1["content_subject"] == row.content_subject))

    # Belt and braces on the id itself: nothing team A owns is reachable.
    assert Enum.all?(theirs, &(&1["id"] != row.id))
    assert team_a.id != team_b.id
  end

  defp deliveries(token) do
    conn =
      :get
      |> conn("/v1/notifications/deliveries")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["deliveries"]
  end
end
