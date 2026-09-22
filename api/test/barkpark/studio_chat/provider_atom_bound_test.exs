defmodule Barkpark.StudioChat.ProviderAtomBoundTest do
  @moduledoc """
  The premise behind the `DOS.StringToAtom` sobelow waiver on
  `Barkpark.StudioChat.Runtime.registered_provider_ready/2`:

      Map.get(providers, provider) || Map.get(providers, String.to_atom(provider)) || %{}

  `String.to_atom/1` on an UNBOUNDED value exhausts the atom table, which is
  never garbage collected, and the node dies. The waiver's premise is that
  `provider` is bounded. That premise was, until this file, written down
  nowhere a test could refute — so nothing red if a future caller widened it.

  THIS FILE IS THAT PREMISE. Its subject is the REACHABILITY of the atom site,
  not the line it sits on. NOTHING BELOW CITES A LINE NUMBER, deliberately:
  the waiver this file explains was itself written line-free because line
  citations rot, and an earlier revision of this moduledoc proved the point by
  pointing at a line an unrelated annotation edit had already moved twice.
  Navigate by module plus function, or by the named attribute or constraint.

  The value at the atom site is `ref.provider`, which `Runtime.open/2` builds as
  `to_string(provider)`. `open/2`'s only `lib/` caller is
  `Barkpark.StudioChat.Recorder.init/1`, which reads
  `Map.get(opts, :provider, "claude")` from the opts it was started with.
  `Recorder.ensure/1` has exactly THREE `lib/` callers, and all three pass the
  PERSISTED `chat_sessions.provider` column:

    * `BarkparkWeb.ChatController` — `session.provider`
    * `BarkparkWeb.Studio.ChatLive` — `socket.assigns.provider`, written only by
      `handle_event("set-provider", …)`, which guards
      `provider in StudioChat.Session.providers()`, or by the session-assign
      helper as `session.provider || "claude"`
    * `Barkpark.CycleFleet` — `recorder_opts/2` → `session.provider`; its own
      session is minted by `create_attempt_session/2` with a literal `"codex"`

  COUNTING THE CALLERS: `Barkpark.CycleFleet` does NOT call the recorder
  directly. It resolves an INJECTED module first — `recorder = value(opts,
  :recorder, Recorder)` — and then calls `recorder.ensure(…)` through that
  variable. So a grep for the direct call `Recorder.ensure(` over `api/lib`
  returns TWO hits, not three; the third is only found by also grepping the
  lowercase `recorder.ensure(`, or by grepping `:recorder` for the injection
  point. A reader who re-verifies the three-caller claim with the obvious
  capitalised grep alone will get a false two and conclude this moduledoc is
  wrong when it is right.

  So the bound is NOT `Runtime.adapter/1`: the
  `execution_target: "registered_host"` clause of `open/2` never calls
  `adapter/1` at all. The bound is the `chat_sessions.provider` COLUMN, held
  twice over — by `Session.create_changeset/2`'s
  `validate_inclusion(:provider, @providers)` over `@providers ~w(claude codex)`,
  and by the Postgres `chat_sessions_provider_check` CHECK constraint added in
  `20260714140000_add_provider_execution_identity_to_chat_sessions`. `provider`
  is create-only: `create_changeset/2` is `Session`'s ONLY changeset and no
  `Repo.update_all` in `Barkpark.StudioChat` sets the column.

  NON-VACUITY, measured not asserted. Widening `@providers` to
  `~w(claude codex gpt)` reds 2 of the 5 arms — the atom-minting arm and the
  roster-drift arm — 5 tests, 2 failures. A SECOND mutation, deleting
  `validate_inclusion(:provider, @providers)` from `create_changeset/2`
  outright, stayed GREEN at 5 tests, 0 failures: the create path is refused by
  `check_constraint(:provider, …)` at the database instead, under the same
  "is invalid" message. So the "changeset refuses" arm below pins the OUTCOME
  of the create path, deliberately NOT which of the two layers produced it — it
  reds only if BOTH go. The DB arm below is the one that isolates the
  constraint: dropping the CHECK constraint reds it alone.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Runtime, Session}

  describe "the value reaching String.to_atom/1 in registered_provider_ready/2" do
    test "creates NO new atom: every roster provider is already an existing atom" do
      # `String.to_atom/1` is only a DoS vector when it MINTS. For every value
      # the roster admits, the atom already exists (compiled into `adapter/1`'s
      # guards as `:claude` / `:codex`), so the site allocates nothing.
      for provider <- Session.providers() do
        assert is_atom(String.to_existing_atom(provider)),
               "#{inspect(provider)} is in the roster but is not an existing atom — " <>
                 "registered_provider_ready/2 would MINT it"
      end
    end

    test "CONTROL: a non-roster string is NOT an existing atom, so the site would mint" do
      # Proves the arm above measures something: an off-roster value is exactly
      # the input that makes the `String.to_atom/1` in
      # `registered_provider_ready/2` dangerous.
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
