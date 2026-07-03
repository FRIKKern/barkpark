defmodule Barkpark.Plugins.Tickets.InboxLiveTest do
  @moduledoc """
  Render-level coverage for the Studio operator-inbox LiveView's presentational
  function components. The `/studio/tickets` route is declared in the
  sibling-owned tickets plugin module and is ABSENT in this worktree, so we do
  NOT mount through the router — instead we `render_component/2` the public
  components directly, feeding them `InboxPresenter` fixtures. This keeps the
  gate green in isolation while still pinning the row/thread/key markup.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Plugins.Tickets.{InboxLive, InboxPresenter}

  @now ~U[2026-07-03 12:00:00Z]

  defp ago(secs), do: DateTime.add(@now, -secs, :second)

  defp model(tickets), do: InboxPresenter.build(tickets, @now)

  describe "inbox_list/1" do
    test "renders the three partitions with dense rows" do
      tickets = [
        %{
          "id" => "open-1",
          "status" => "open",
          "key_name" => "Gyldendal — Kari",
          "subject" => "Cannot download my export",
          "waiting_since" => ago(21_600),
          "messages" => [%{"author_kind" => "submitter", "at" => ago(21_600), "attachments" => ["a1"]}]
        },
        %{
          "id" => "ans-1",
          "status" => "answered",
          "key_name" => "Acme — Bob",
          "subject" => "Reset question",
          "submitter_seen_at" => ago(3600),
          "waiting_since" => ago(10_000),
          "messages" => [%{"author_kind" => "operator", "at" => ago(7200)}]
        },
        %{
          "id" => "closed-1",
          "status" => "closed",
          "key_name" => "Zed",
          "subject" => "Old thing",
          "messages" => [%{"author_kind" => "operator", "at" => ago(99_999)}]
        }
      ]

      html = render_component(&InboxLive.inbox_list/1, %{presenter: model(tickets), data_error: nil})

      assert html =~ ~s(data-test-id="needs-answer")
      assert html =~ ~s(data-test-id="waiting-on-them")
      assert html =~ ~s(data-test-id="recently-closed")

      # needs-answer row: key pill, subject, paperclip, waiting age
      assert html =~ "Gyldendal — Kari"
      assert html =~ "Cannot download my export"
      assert html =~ "📎"
      assert html =~ "6h"

      # answered row carries the seen signal
      assert html =~ "seen 1h ago"
      # closed row present
      assert html =~ "Old thing"
    end

    test "empty presenter renders the inbox-zero honest state" do
      html = render_component(&InboxLive.inbox_list/1, %{presenter: model([]), data_error: nil})
      assert html =~ ~s(data-test-id="inbox-zero")
      assert html =~ "Inbox zero"
    end

    test "needs-answer rows are amber/warn-toned and clickable" do
      t = %{"id" => "o9", "status" => "open", "key_name" => "K", "subject" => "S", "waiting_since" => ago(60)}
      html = render_component(&InboxLive.inbox_list/1, %{presenter: model([t]), data_error: nil})

      assert html =~ "bp-tk-tone-warn"
      assert html =~ ~s(phx-click="open_thread")
      assert html =~ ~s(phx-value-id="o9")
    end
  end

  describe "ticket_row/1" do
    test "shows the seen signal only when show_seen is true" do
      row = %{
        id: "r1",
        key_name: "Kari",
        subject: "Hi",
        waiting_age: "3h",
        message_count: 2,
        has_attachments?: false,
        seen: "not seen yet"
      }

      shown = render_component(&InboxLive.ticket_row/1, %{row: row, tone: "info", show_seen: true})
      assert shown =~ "not seen yet"
      assert shown =~ ~s(data-test-id="seen-signal")

      hidden = render_component(&InboxLive.ticket_row/1, %{row: row, tone: "warn", show_seen: false})
      refute hidden =~ "not seen yet"
    end

    test "omits the paperclip when there are no attachments" do
      row = %{id: "r", key_name: "K", subject: "S", waiting_age: "1h", message_count: 1, has_attachments?: false, seen: nil}
      html = render_component(&InboxLive.ticket_row/1, %{row: row, tone: "warn", show_seen: false})
      refute html =~ "📎"
      assert html =~ "💬 1"
    end
  end

  describe "thread_detail/1" do
    test "renders a full-width timeline with author chips and a split composer" do
      thread = %{
        "id" => "t1",
        "subject" => "Broken login",
        "status" => "open",
        "key_name" => "Gyldendal — Kari",
        "messages" => [
          %{"author_kind" => "submitter", "author_name" => "Kari", "body" => "I cannot log in", "at" => ago(7200), "attachments" => ["shot.png"]},
          %{"author_kind" => "operator", "author_name" => "Support", "body" => "Try resetting", "at" => ago(3600), "attachments" => []}
        ]
      }

      html = render_component(&InboxLive.thread_detail/1, %{thread: thread})

      assert html =~ ~s(data-test-id="thread-timeline")
      assert html =~ "I cannot log in"
      assert html =~ "Try resetting"
      assert html =~ "Kari"
      assert html =~ "Support"
      # operator event styling + tinted pill
      assert html =~ "bp-tk-event-operator"
      assert html =~ "bp-tk-oppill"
      # attachment link
      assert html =~ "shot.png"

      # split submit (name/value on the buttons, single phx-submit) + confirmed close
      assert html =~ ~s(phx-submit="answer")
      assert html =~ ~s(data-test-id="answer-btn")
      assert html =~ ~s(data-test-id="answer-close-btn")
      assert html =~ ~s(name="action" value="answer")
      assert html =~ ~s(name="action" value="close")
      assert html =~ ~s(name="ticket_id")
      assert html =~ ~s(data-confirm=)
      assert html =~ ~s(phx-click="close_ticket")
    end

    test "nil thread renders the unavailable honest state" do
      html = render_component(&InboxLive.thread_detail/1, %{thread: nil})
      assert html =~ ~s(data-test-id="thread-missing")
      assert html =~ "Ticket unavailable"
    end
  end

  describe "key_management/1" do
    test "lists keys with mint form and rotate/pause actions" do
      keys = [
        %{"id" => "k1", "name" => "Gyldendal — Kari", "paused_at" => nil, "ticket_count" => 3},
        %{"id" => "k2", "name" => "Spammy", "paused_at" => ago(100), "ticket_count" => 12}
      ]

      html = render_component(&InboxLive.key_management/1, %{keys: keys, mint_result: nil})

      assert html =~ ~s(data-test-id="mint-form")
      assert html =~ "Gyldendal — Kari"
      assert html =~ ~s(phx-click="rotate_key")
      # active key offers Pause, paused key offers Resume
      assert html =~ ~s(phx-click="pause_key")
      assert html =~ ~s(phx-click="unpause_key")
      assert html =~ "active"
      assert html =~ "paused"
    end

    test "empty key list shows the guidance row" do
      html = render_component(&InboxLive.key_management/1, %{keys: [], mint_result: nil})
      assert html =~ ~s(data-test-id="keys-empty")
      assert html =~ "that key is their identity"
    end

    test "mint_result surfaces the one-time secret + handoff card" do
      html =
        render_component(&InboxLive.key_management/1, %{
          keys: [],
          mint_result: %{raw: "bptk_supersecret", key_name: "Gyldendal — Kari"}
        })

      assert html =~ ~s(data-test-id="mint-result")
      assert html =~ "Handoff card"
      assert html =~ "bptk_supersecret"
      assert html =~ "shown"
    end
  end
end
