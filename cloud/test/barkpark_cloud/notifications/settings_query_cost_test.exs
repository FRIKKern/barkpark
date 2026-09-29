defmodule BarkparkCloud.Notifications.SettingsQueryCostTest do
  @moduledoc """
  task-6aadf4ff08101b20 — the row was filed on the finding that
  `Notifications.get_or_create_settings/1` "is read TWICE per
  `dispatch_event/3`", measured as a constant 2
  `email_notification_settings` events on `[:barkpark_cloud, :repo, :query]`.

  ## The count reproduces; the reading of it does not

  Counting the same telemetry here reproduces the filed table EXACTLY — 5 / 7 /
  14 total queries at team sizes 1 / 3 / 10, of which `email_notification_settings`
  is 2 at every size. But bucketing those two events by SQL VERB, which the
  original count did not, shows what they are:

      1x email_notification_settings SELECT
      1x email_notification_settings INSERT

  One SELECT and one INSERT — the two halves of `get_or_create_settings/1`'s
  own lazy create, on a team whose settings row does not exist yet. Not two
  reads. `get_or_create_settings/1` is called exactly ONCE in
  `dispatch_event/3` (`notifications.ex`, the `settings = ` binding at the top
  of the function body); every other call site in the module is a separate
  public or private entry point and none of them nests inside it.

  So the second event is neither a read-after-write, nor a cache miss, nor a
  genuine duplicate: it is the CREATE. There is no second read to collapse,
  and the whole cost is a FIRST-DISPATCH one-off — a second dispatch on the
  same team costs 1 settings query, asserted below.

  ## Why the assertions are shaped this way

  A total-count assertion alone cannot tell SELECT+INSERT from SELECT+SELECT,
  which is the exact confusion that produced the row. Every assertion here is
  keyed on `{source, verb}` pairs, so a future change that reintroduces a real
  second READ reds by name instead of passing at "still 2".

  Cost honesty, restated so nothing here reads as a performance claim: this
  path sends N emails SYNCHRONOUSLY and writes one `notification_deliveries`
  row per recipient. The settings work is 2 queries out of `3+N` on the first
  dispatch and 1 thereafter. Nothing in this file is a latency result.

  (The `3+N` the row quotes is the SECOND-dispatch shape; the first dispatch,
  which is what the filed table measured, is `4+N`. Both are asserted below.)
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.EmailSettings

  # An event with a default-ON per-event toggle, so the fan-out actually runs.
  # `:test` does NOT: it is absent from both `@always_send` and
  # `EmailSettings.events/0`, so `should_send?/2` is false and the dispatch
  # costs 2 queries at EVERY team size — a fixture that would have made this
  # whole file vacuous.
  @event :subscription_past_due

  @settings "email_notification_settings"

  defp team_of_size(n_members) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    for i <- 1..n_members do
      {:ok, user} =
        Accounts.register_user(%{
          email: "m#{i}-#{n}@example.com",
          password: "correct horse staple"
        })

      {:ok, _} = Accounts.add_member(team, user, if(i == 1, do: "owner", else: "member"))
    end

    team
  end

  # Every `[:barkpark_cloud, :repo, :query]` event raised inside `fun`, as
  # `{source, verb}` — the verb is what distinguishes a read from a write.
  defp census(fun) do
    ref = make_ref()
    me = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:barkpark_cloud, :repo, :query],
      fn _event, _measure, meta, _cfg -> send(me, {ref, meta[:source], verb(meta[:query])}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain(ref, [])
  end

  defp verb(query) when is_binary(query), do: query |> String.split(" ", parts: 2) |> hd()
  defp verb(_other), do: "?"

  defp drain(ref, acc) do
    receive do
      {^ref, source, verb} -> drain(ref, [{source, verb} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp settings_events(events), do: Enum.filter(events, fn {source, _} -> source == @settings end)

  ## ── The two settings events, counted and CLASSIFIED ──────────────────────

  describe "the constant 2 is SELECT + INSERT, not two reads" do
    for size <- [1, 3, 10] do
      test "team size #{size}", _ctx do
        size = unquote(size)
        team = team_of_size(size)

        # PRECONDITION, asserted not assumed: the settings row does not exist
        # yet. `Accounts.create_team/1` does not make one — only the signup
        # `with` chain calls `ensure_settings/1`. If this ever starts creating
        # the row, the create half below stops being exercised and this test
        # would silently measure the wrong thing.
        refute Repo.get_by(EmailSettings, team_id: team.id)

        events =
          census(fn -> :ok = Notifications.dispatch_event(team, @event, %{name: "acme"}) end)

        # The filed table, reproduced: 5 / 7 / 14 at sizes 1 / 3 / 10. The
        # shape is `4 + N`, not the `3 + N` the row inherited from its sibling:
        # 2 settings + 1 `team_memberships` + 1 `users` + one delivery INSERT
        # per member. `3 + N` is the SECOND dispatch, once the row exists.
        assert length(events) == 4 + size

        # And the classification: ONE read, ONE write. Not `== 2`, which is
        # true of SELECT+SELECT too and is exactly how the row got its headline.
        assert settings_events(events) == [{@settings, "SELECT"}, {@settings, "INSERT"}]
      end
    end

    test "a SECOND dispatch on the same team costs ONE settings query" do
      team = team_of_size(1)
      :ok = Notifications.dispatch_event(team, @event, %{name: "acme"})

      # The create half has now run, so the row exists — the whole reason the
      # first dispatch cost two.
      assert Repo.get_by(EmailSettings, team_id: team.id)

      events = census(fn -> :ok = Notifications.dispatch_event(team, @event, %{name: "acme"}) end)

      assert settings_events(events) == [{@settings, "SELECT"}]
      assert length(events) == 4
    end
  end

  ## ── The not-yet-created case the create half exists for ──────────────────

  describe "the lazy create is load-bearing" do
    test "a team with no settings row is dispatched to, and the row is created" do
      team = team_of_size(1)
      refute Repo.get_by(EmailSettings, team_id: team.id)

      :ok = Notifications.dispatch_event(team, @event, %{name: "acme"})

      # The alert went out — the absence of a settings row is not silence.
      assert %EmailSettings{} = settings = Repo.get_by(EmailSettings, team_id: team.id)
      assert settings.alerts_enabled

      recipients =
        Repo.all(
          from(d in BarkparkCloud.Notifications.Delivery,
            where: d.team_id == ^team.id and d.event == ^Atom.to_string(@event),
            select: d.recipient
          )
        )

      assert recipients == Accounts.list_team_member_emails(team)
    end

    test "get_or_create_settings/1 returns the created row without re-reading it" do
      team = team_of_size(1)
      refute Repo.get_by(EmailSettings, team_id: team.id)

      events = census(fn -> %EmailSettings{} = Notifications.get_or_create_settings(team) end)

      # The happy path of the create half returns `insert`'s own struct. A
      # read-after-write would show a trailing SELECT here — it does not, which
      # is the direct refutation of the "the second read is a read-after-write"
      # hypothesis the row asked to be ruled out.
      assert events == [{@settings, "SELECT"}, {@settings, "INSERT"}]
    end
  end
end
