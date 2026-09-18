defmodule BarkparkCloud.Notifications.MemberJoinedDispatchTest do
  @moduledoc """
  cch-w30-bl-member-joined-alert — a team learns when somebody ACCEPTS an
  invitation, and it learns it from a producer that runs AFTER the commit.

  ## What was missing, and what this is NOT

  Wave 30 deleted a `member_invited` column: it promised a team an email at the
  moment an invitation was SENT, which is a duplicate of the letter the invitee
  already gets (`Transactional.deliver_invite/1`), and nothing in `cloud/lib`
  dispatched it. The fact nobody was told is the ACCEPTANCE —
  `Accounts.accept_invitation/2` added a person to a team and no existing member
  learned of it. `:member_joined` is that moment. It is a different event with a
  different producer, not `member_invited` under a new name, and
  `__app.test.mjs`'s dead-name loop keeps the old one dead.

  ## The count this file actually proves

  The row's criterion 1 asks for "exactly one Delivery row after a real
  invitation acceptance". Read literally against the mechanism that is not what
  a correct implementation produces: `dispatch_event/3` fans to
  `Accounts.list_team_member_emails/1` and writes ONE `Delivery` row PER
  RECIPIENT, and after an acceptance the team has two members — the owner who
  invited and the person who just joined. So the assertion below is the one that
  carries the criterion's meaning: exactly ONE row per recipient (the dispatch
  fired once, not twice, and not once per stage), with the recipient set stated
  exactly rather than counted loosely. A second dispatch — or a dispatch moved
  inside the loop — reds it.

  ## The control is the toggle, and the default is OFF

  A join is a success, and `EmailSettings`'s rule is failures-on /
  successes-off, so the column ships `default: false`. The control arm therefore
  needs no setup at all: a team that never touched the toggle must observe ZERO
  `member_joined` rows after the same real acceptance.

  `async: false`: these read the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail
  alias BarkparkCloud.Notifications.Render
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"
  @subject "A new member joined your team"

  ## ── Fixtures ──────────────────────────────────────────────────────────────

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})

    user
  end

  defp owned_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    owner = user_fixture()
    {:ok, _} = Accounts.add_member(team, owner, "owner")
    {team, owner}
  end

  # Drain the mailbox of everything the SETUP sent (registration + the invite
  # letter), so what remains is what the acceptance produced.
  defp flush_emails(acc \\ []) do
    receive do
      {:email, email} -> flush_emails([email | acc])
    after
      50 -> acc
    end
  end

  # A real invitation, really accepted, through the public context functions.
  defp invite_and_accept(team, owner, role) do
    invitee = user_fixture()

    {:ok, %{token: raw}} = Accounts.invite_member(team, invitee.email, role, owner)
    flush_emails()

    {:ok, membership} = Accounts.accept_invitation(raw, invitee)
    {invitee, membership}
  end

  defp deliveries(team, event) do
    Repo.all(
      from(d in Delivery,
        where: d.team_id == ^team.id and d.event == ^event,
        order_by: [asc: d.recipient]
      )
    )
  end

  ## ── §1 the producer ───────────────────────────────────────────────────────

  describe "§1 accept_invitation/2 dispatches member_joined" do
    test "one Delivery row per recipient, and the recipient set is exactly the team" do
      {team, owner} = owned_team()
      {:ok, _} = Notifications.update_settings(team, %{"member_joined" => true})

      {invitee, membership} = invite_and_accept(team, owner, "admin")
      assert membership.role == "admin"

      rows = deliveries(team, "member_joined")

      # THE CRITERION'S SENSE: exactly ONE row for the person who was already on
      # the team. Two rows here is a double dispatch; zero is no dispatch.
      owner_rows = Enum.filter(rows, &(&1.recipient == owner.email))

      assert [%Delivery{status: "sent", kind: "alert"}] = owner_rows,
             "expected exactly one member_joined Delivery row for the existing member, got " <>
               inspect(owner_rows, pretty: true)

      # And the whole population, stated rather than left implicit: dispatch_event/3
      # fans to every team member, so after the acceptance that is owner + joiner.
      assert Enum.map(rows, & &1.recipient) |> Enum.sort() ==
               Enum.sort([owner.email, invitee.email]),
             "the recipient set is not the team's member list — the fan-out moved"
    end

    test "CONTROL: a team that never enabled the toggle observes ZERO rows" do
      {team, owner} = owned_team()

      # No update_settings call at all — the column's shipped default is false.
      assert %EmailSettings{member_joined: false} = Notifications.get_or_create_settings(team)

      {_invitee, _membership} = invite_and_accept(team, owner, "member")

      assert deliveries(team, "member_joined") == [],
             "a join is a SUCCESS and successes are opt-in — a default-off team was mailed"
    end

    test "the dispatch is POST-COMMIT by construction, not by hope" do
      source = File.read!(Path.expand("../../../lib/barkpark_cloud/accounts.ex", __DIR__))

      [dispatch] =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ "dispatch_event(team, :member_joined" end)
        |> Enum.map(&elem(&1, 1))

      {txn_start, txn_body} = transaction_owner(source)

      assert dispatch < txn_start or dispatch > txn_body,
             """
             The :member_joined dispatch sits INSIDE do_accept_invitation/2's
             Repo.transaction block (line #{dispatch}).

             A notification send there runs on the same connection as an
             uncommitted write, inside the `lock: "FOR UPDATE"` on the
             invitation row: a recipient read, an SMTP round-trip and a
             notification_deliveries insert all held under a row lock, and a
             rollback after the mail left tells a team about a member who was
             never added. The wave-28 discipline is a private function that owns
             the transaction and a public wrapper that dispatches on its {:ok, _}.
             """

      assert source =~ "defp do_accept_invitation(",
             "the transaction is no longer split out of the public function — re-read this guard"
    end
  end

  # Line span of `defp do_accept_invitation/2` — the function that owns the
  # transaction. DERIVED, never a pinned ordinal: a pin decays in the silent
  # direction (the file shifts, the span stops covering the transaction, the
  # assertion passes measuring nothing).
  defp transaction_owner(source) do
    lines = String.split(source, "\n")

    start =
      Enum.find_index(lines, &String.starts_with?(&1, "  defp do_accept_invitation(")) + 1

    stop =
      lines
      |> Enum.drop(start)
      |> Enum.find_index(&(&1 == "  end"))
      |> Kernel.+(start + 1)

    assert Enum.slice(lines, (start - 1)..(stop - 1)) |> Enum.any?(&(&1 =~ "Repo.transaction(")),
           "do_accept_invitation/2 no longer owns a Repo.transaction — this guard is vacuous"

    {start, stop}
  end

  ## ── §2 the JOINED vocabulary ──────────────────────────────────────────────

  describe "§2 the copy says JOINED, on both rails" do
    test "the alert email's rendered subject names a JOIN, never an invite" do
      {team, owner} = owned_team()
      {:ok, _} = Notifications.update_settings(team, %{"member_joined" => true})

      {invitee, _} = invite_and_accept(team, owner, "admin")

      sent = flush_emails()

      email =
        Enum.find(sent, fn e -> e.subject == @subject end) ||
          flunk(
            "no email with subject #{inspect(@subject)}; got #{inspect(Enum.map(sent, & &1.subject))}"
          )

      assert email.subject =~ "joined"
      refute email.subject =~ "invited"

      assert email.text_body =~ "#{invitee.email} joined as an admin on #{team.name}."
      refute email.text_body =~ "invited"
    end

    test "the built subject is the same one whatever the payload carries" do
      built =
        EventEmail.build(
          %EmailSettings{},
          :member_joined,
          %{"name" => "acme", "email" => "pat@acme.com", "role" => "member"},
          "someone@example.com"
        )

      assert built.subject == @subject
      assert built.text_body == "pat@acme.com joined as a member on acme."
    end

    test "the chat rail renders a NAMED arm at :info, with the same clause" do
      payload = %{
        "name" => "acme",
        "site" => "acme",
        "email" => "pat@acme.com",
        "role" => "owner"
      }

      assert {"Member joined", body, :info} = Render.render("member_joined", payload)
      assert body == "pat@acme.com joined as the owner on acme."

      # One owner for the sentence — the email arm calls the same function.
      assert Render.joined_clause(payload) == "pat@acme.com joined as the owner"
    end

    test "the clause degrades rather than inventing a person or a role" do
      assert Render.joined_clause(%{}) == "a new member joined"
      assert Render.joined_clause(%{"email" => "pat@acme.com"}) == "pat@acme.com joined"

      assert Render.joined_clause(%{"email" => "pat@acme.com", "role" => "auditor"}) ==
               "pat@acme.com joined"
    end

    test "the event is in the vocabulary every rail derives from" do
      assert :member_joined in EmailSettings.events()
      refute :member_invited in EmailSettings.events()
      assert "member_joined" in Notifications.chat_events()
    end
  end
end
