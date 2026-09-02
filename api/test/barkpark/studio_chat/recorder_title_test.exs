defmodule Barkpark.StudioChat.RecorderTitleTest do
  @moduledoc """
  `ct-bl-recorder-titles` — the AI title is PUSHED to every surface off the
  Recorder's topics, and is never a `send/2` to whoever happened to start the
  generation.

  What each half buys, stated because the two topics look redundant:

    * `Recorder.topic/1` (NEW) is the per-session channel `ChatController`'s SSE
      forwarder subscribes to, and ONLY that (D24). Without a title event here a
      headless client — `bp chat`, mobile — cannot learn a title from the
      transport it already holds, which is exactly why charter D15 shipped a
      re-GET-the-session-every-turn-boundary workaround.
    * `Recorder.activity_topic/0` (pre-existing, D69h) is the global fleet
      channel Studio's sidebar and the `FleetHub` key off. Asserted here so the
      new half cannot be mistaken for a MOVE: `FleetHubTitleTest` still passes
      because this event still ships.

  These tests run against the REAL store (`Barkpark.StudioChat`), not a fake:
  the duplicate-generation case below is only meaningful if the clobber guard
  under test is the actual `title_source == "default"` SQL WHERE. `async: false`
  gives the DataCase sandbox `shared: true`, which is what lets `kick_title`'s
  supervised task reach the Repo at all.
  """
  # async: false — the title seams are Application env (process-global VM state)
  # and the supervised generation task needs the SHARED sandbox connection.
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Titles

  defmodule FailingAdapter do
    # The Anthropic layer always falls through, so the pipeline is keyed to the
    # fake CLI below and NEVER reaches the network — even on a host that happens
    # to export ANTHROPIC_API_KEY.
    def post(_url, _body, _headers), do: {:error, :offline}
  end

  defmodule FakeCli do
    # Steerable per test, so the duplicate-generation case can offer a SECOND,
    # different title and prove the store refuses it.
    def run(_binary, _args), do: Application.get_env(:barkpark, :test_title_cli, {:error, :unset})
  end

  setup do
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, FailingAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
    Application.put_env(:barkpark, :test_title_cli, {:ok, ~s({"title":"Recorder title"})})

    on_exit(fn ->
      for k <- [:studio_chat_title_http_adapter, :studio_chat_title_cli, :test_title_cli] do
        Application.delete_env(:barkpark, k)
      end
    end)

    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"})
    %{session: session}
  end

  # ── A. the new half: the per-session topic every headless client holds ─────

  describe "Recorder.broadcast_title/2 on the session topic" do
    test "an accepted AI title arrives ONCE, carrying session identity + the final title",
         %{session: s} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))

      sid = s.id
      {:ok, _task} = Titles.kick_title(sid, "make the login test stop flaking")

      # PUSHED, not polled: nothing here re-reads the session.
      assert_receive {:chat_title, ^sid, "Recorder title"}, 5_000
      # …and exactly once — a second delivery on this topic would double the
      # frame every SSE client writes to its wire.
      refute_receive {:chat_title, ^sid, _}, 300

      assert StudioChat.get_session(sid).title == "Recorder title"
    end

    test "the SAME write still rides the activity topic (sidebar + FleetHub, D69h)",
         %{session: s} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))

      sid = s.id
      {:ok, _task} = Titles.kick_title(sid, "make the login test stop flaking")

      # Two topics, one write: both fire, and neither fires twice. Subscribing
      # to both is what a Studio tab does, so this also pins the exact duplicate
      # ChatLive's handler is written to drop.
      assert_receive {:chat_title, ^sid, "Recorder title"}, 5_000
      assert_receive {:chat_title, ^sid, "Recorder title"}, 1_000
      refute_receive {:chat_title, ^sid, _}, 300
    end

    test "no live Recorder is required — a settled title publishes for a dead runtime",
         %{session: s} do
      # The realistic `bp chat` shape: a one-shot send whose runtime idled out
      # before the ~1s title call returned. Routing this through the Recorder
      # PROCESS would silently drop it; a module function cannot.
      assert Recorder.whereis(s.id) == nil

      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))
      sid = s.id
      {:ok, _task} = Titles.kick_title(sid, "make the login test stop flaking")

      assert_receive {:chat_title, ^sid, "Recorder title"}, 5_000
    end

    test "a session topic carries only its OWN session's title", %{session: s} do
      other = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(other))

      {:ok, _task} = Titles.kick_title(s.id, "make the login test stop flaking")

      # Tenancy by construction: the topic embeds the id, so a subscriber can
      # only ever be on its own session's channel — no filtering to get wrong.
      refute_receive {:chat_title, _, _}, 500
    end
  end

  # ── B. convergence: duplicate generation + reconnect ───────────────────────

  describe "clients converge on the persisted current title" do
    test "a SECOND generation is refused by the clobber guard — no second event, no flicker",
         %{session: s} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))
      sid = s.id

      {:ok, _} = Titles.kick_title(sid, "make the login test stop flaking")
      assert_receive {:chat_title, ^sid, "Recorder title"}, 5_000

      # A duplicate kick (a retried send, a second tab, a re-spawned runtime)
      # generating a DIFFERENT title. `title_source` is now "ai", so the store's
      # WHERE matches no row and `kick_title` publishes nothing: the wire stays
      # silent and the rendered title cannot flicker between two candidates.
      Application.put_env(:barkpark, :test_title_cli, {:ok, ~s({"title":"Second guess"})})
      {:ok, _} = Titles.kick_title(sid, "make the login test stop flaking")

      refute_receive {:chat_title, ^sid, _}, 1_000

      row = StudioChat.get_session(sid)
      assert row.title == "Recorder title"
      assert row.title_source == "ai"
    end

    test "a human rename is never announced as an AI title", %{session: s} do
      {:ok, _} = StudioChat.rename(s.id, "My own name for this")
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))

      {:ok, _} = Titles.kick_title(s.id, "make the login test stop flaking")

      refute_receive {:chat_title, _, _}, 1_000
      assert StudioChat.get_session(s.id).title == "My own name for this"
    end

    test "a reconnecting client re-reads the SAME title the event carried", %{session: s} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(s.id))
      sid = s.id

      {:ok, _} = Titles.kick_title(sid, "make the login test stop flaking")
      assert_receive {:chat_title, ^sid, pushed}, 5_000

      # The title frame is deliberately id-less and unreplayable (D5), so a
      # reconnect learns the title the way `bp chat` already learns everything
      # settled: off the session read. It must agree with what was pushed —
      # otherwise a reconnect would visibly revert the header.
      assert StudioChat.get_session(sid).title == pushed

      # And the reconnect itself replays nothing title-shaped: re-subscribing
      # produces no event, so the client's converged state stays put.
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, Recorder.topic(sid))
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
      refute_receive {:chat_title, _, _}, 300
    end
  end
end
