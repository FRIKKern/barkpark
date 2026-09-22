defmodule Barkpark.StudioChat.ProviderAtomBoundTest do
  @moduledoc """
  The premise behind the `DOS.StringToAtom` sobelow waiver on
  `Barkpark.StudioChat.Runtime.registered_provider_ready/2`
  (`lib/barkpark/studio_chat/runtime.ex:554`):

      Map.get(providers, provider) || Map.get(providers, String.to_atom(provider)) || %{}

  `String.to_atom/1` on an UNBOUNDED value exhausts the atom table, which is
  never garbage collected, and the node dies. The waiver's premise is that
  `provider` is bounded. That premise was, until this file, written down
  nowhere a test could refute — so nothing red if a future caller widened it.

  THIS FILE IS THAT PREMISE. Its subject is the REACHABILITY of the atom site,
  not the line itself.

  The value at the atom site is `ref.provider`, `to_string(provider)` from
  `Runtime.open/2` (runtime.ex:344-346), whose only `lib/` caller is
  `Recorder.init/1` (recorder.ex:326) reading `Map.get(opts, :provider, "claude")`
  (recorder.ex:259). `Recorder.ensure/1` has exactly THREE `lib/` callers, and
  all three pass the PERSISTED `chat_sessions.provider` column:

    * `barkpark_web/controllers/chat_controller.ex:1013` — `session.provider`
    * `barkpark_web/live/studio/chat_live.ex:4710` — `socket.assigns.provider`,
      written only by `handle_event("set-provider", …)` (chat_live.ex:692-694),
      which guards `provider in StudioChat.Session.providers()`, or from
      `session.provider || "claude"` (chat_live.ex:4990)
    * `cycle_fleet.ex:1748` — `recorder_opts/2` → `session.provider`
      (cycle_fleet.ex:4707); its own session is minted with a literal `"codex"`
      (cycle_fleet.ex:4694)

  So the bound is NOT `Runtime.adapter/1` (runtime.ex:146/149): the
  `execution_target: "registered_host"` clause of `open/2` never calls
  `adapter/1` at all. The bound is the chat_sessions.provider COLUMN, held
  twice over — by `Session.create_changeset/2`'s
  `validate_inclusion(:provider, ~w(claude codex))` (session.ex:26, :209) and by
  the Postgres `chat_sessions_provider_check` CHECK constraint
  (priv/repo/migrations/20260714140000_…:22-23). `provider` is create-only:
  `create_changeset/2` is session.ex's ONLY changeset and no `update_all` in
  `studio_chat.ex` touches the column.

  NON-VACUITY, measured not asserted. Widening `@providers` to
  `~w(claude codex gpt)` (session.ex:26) reds 2 of the 5 arms — the
  atom-minting arm and the roster-drift arm — 5 tests, 2 failures. A SECOND
  mutation, deleting `validate_inclusion(:provider, @providers)` from
  `create_changeset/2` outright, stayed GREEN at 5/0: the create path is
  refused by `check_constraint(:provider, …)` at the database instead, under
  the same "is invalid" message. So the "changeset refuses" arm below pins the
  OUTCOME of the create path, deliberately NOT which of the two layers
  produced it — it reds only if BOTH go. The DB arm below is the one that
  isolates the constraint.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Runtime, Session}

  describe "the value reaching String.to_atom/1 at runtime.ex:554" do
    test "creates NO new atom: every roster provider is already an existing atom" do
      # `String.to_atom/1` is only a DoS vector when it MINTS. For every value
      # the roster admits, the atom already exists (compiled into `adapter/1`'s
      # guards as `:claude` / `:codex`), so the site allocates nothing.
      for provider <- Session.providers() do
        assert is_atom(String.to_existing_atom(provider)),
               "#{inspect(provider)} is in the roster but is not an existing atom — " <>
                 "runtime.ex:554 would MINT it"
      end
    end

    test "CONTROL: a non-roster string is NOT an existing atom, so the site would mint" do
      # Proves the arm above measures something: an off-roster value is exactly
      # the input that makes runtime.ex:554 dangerous.
      off_roster = "provider-#{System.unique_integer([:positive])}"
      refute off_roster in Session.providers()

      assert_raise ArgumentError, fn -> String.to_existing_atom(off_roster) end
    end

    test "the roster the atom site is bounded by IS the roster adapter/1 resolves" do
      # If these two drift, a provider could be persistable but unresolvable
      # (or vice versa) and the reachability argument above stops holding.
      for provider <- Session.providers() do
        assert is_atom(Runtime.adapter(provider))
      end

      assert Session.providers() == ~w(claude codex)
    end
  end

  describe "the bound on chat_sessions.provider" do
    # Layer-agnostic BY DESIGN (see the mutation log above): `validate_inclusion`
    # and the CHECK constraint both surface as `provider: ["is invalid"]`.
    test "the create path refuses an off-roster provider" do
      off_roster = "provider-#{System.unique_integer([:positive])}"

      assert {:error, changeset} =
               StudioChat.create_session(%{
                 id: Ecto.UUID.generate(),
                 provider: off_roster,
                 cwd: "/tmp/provider-atom-bound"
               })

      assert %{provider: ["is invalid"]} = errors_on(changeset)
    end

    test "the DATABASE refuses an off-roster provider even with the changeset bypassed" do
      # The changeset is one layer; a raw write that skips it must still be
      # refused, otherwise a persisted off-roster row would feed the atom site
      # directly. The write is an UPDATE on a row this test just created, so no
      # other agent's rows on the shared test DB are involved.
      id = Ecto.UUID.generate()
      assert {:ok, %Session{provider: "claude"}} = StudioChat.create_session(%{id: id})

      off_roster = "provider-#{System.unique_integer([:positive])}"

      assert_raise Postgrex.Error, ~r/chat_sessions_provider_check/, fn ->
        Repo.query!("UPDATE chat_sessions SET provider = $1 WHERE id = $2", [
          off_roster,
          Ecto.UUID.dump!(id)
        ])
      end
    end
  end
end
