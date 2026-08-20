defmodule BarkparkCloud.Notifications.EventVocabularyCensusTest do
  @moduledoc """
  cch-w42-s5 — a CENSUS over the notification event vocabulary: every event this
  control plane can dispatch must have a NAMED arm in both human-facing
  renderers, so an unnamed event can no longer ship green at `:info`.

  ## What goes wrong without it

  `Render.render/2`'s last arm is `other -> {"Barkpark Cloud", "Event: \#{other}
  for \#{site}.", :info}` and `EventEmail`'s final private clause is
  `{"Barkpark Cloud notification", "Event: \#{event}.\#{detail(payload)}"}`.
  `:info` really is GREEN on Discord — `channels/discord.ex` holds
  `@colors %{error: 15_158_332, warning: 16_761_095, info: 3_066_993}`
  (3_066_993 = 0x2ECC71) and looks the colour up with `Map.get(@colors,
  severity, @colors.info)`, so BOTH the fallback severity and the fallback
  colour default to green. A future `backup_failed` would reach a person titled
  "Barkpark Cloud", coloured like a success.

  ## This is LATENT, not live

  All six `EmailSettings.events/0` atoms — and `"test"` — have named arms today.
  Nobody is being told anything wrong. What was missing is that NOTHING drove
  the vocabulary against either renderer: the console's bidirectional census
  (`__app.test.mjs` "cch-w30-s1 census") checks producer <-> offer, not whether a
  dispatched event RENDERS as itself, and `render_test.exs` pins the arms it
  knows about one by one — it stays fully green when a seventh atom appears.

  ## Limits, stated so nobody over-reads a green run

    * It proves an arm EXISTS, not that it is CORRECT, and it is BLIND TO
      SEVERITY: a `{"Backup failed", "…", :info}` arm passes here while still
      painting a failure Discord-green. "Failure-worded events must not render
      `:info`" is a separate assertion and is NOT claimed here.
    * `digest_email.ex`, `transactional.ex`, `delivery_reason.ex` and
      `withhold.ex` were not audited for their own catch-alls.
    * `Notifications.@chat_always_send` (`trial_expiring`) is NOT covered: it has
      no public accessor, and re-typing the literal here would be the pinned-list
      smell. `trial_expiring` does have a named `Render` arm today; that is
      residue, filed, not asserted.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail
  alias BarkparkCloud.Notifications.Render

  # The two fallback strings, pinned by the third test against a genuinely
  # unknown event. Without that pin, renaming a fallback would make the two
  # censuses match nothing and report clean — vacuously green.
  @render_catch_all_title "Barkpark Cloud"
  @email_catch_all_subject "Barkpark Cloud notification"

  # A name no producer emits. Deliberately ugly so it cannot collide with a real
  # event someone adds later.
  @unknown_event "__census_definitely_unknown_event__"

  @payload %{"site" => "acme", "name" => "acme"}

  # No Repo, no sandbox: `EventEmail.build/4` only reads From fields off the
  # struct, and `Render.render/2` is pure.
  defp settings, do: %EmailSettings{}

  defp render_title(event) when is_binary(event) do
    {title, _body, _severity} = Render.render(event, @payload)
    title
  end

  # `render/2` inside `EventEmail` is `defp` — every clause is private — so the
  # census goes through the PUBLIC `build/4` and reads the built subject.
  defp email_subject(event) when is_atom(event) do
    EventEmail.build(settings(), event, @payload, "someone@example.com").subject
  end

  test "every chat event has a NAMED Render.render/2 arm (the catch-all ships :info = Discord GREEN)" do
    unnamed =
      Notifications.chat_events()
      |> Enum.filter(&(render_title(&1) == @render_catch_all_title))

    assert unnamed == [],
           """
           These dispatchable events have no named Render.render/2 arm and fall to the catch-all:

               #{inspect(unnamed)}

           The catch-all renders {"#{@render_catch_all_title}", "Event: <event> for <site>.", :info},
           and :info is Discord GREEN (channels/discord.ex @colors info: 3_066_993 = 0x2ECC71).
           A failure event landing here reaches a person looking like a success.
           Add a named arm in cloud/lib/barkpark_cloud/notifications/render.ex.
           """
  end

  test "every email event has a NAMED EventEmail subject" do
    unnamed =
      EmailSettings.events()
      |> Enum.filter(&(email_subject(&1) == @email_catch_all_subject))

    assert unnamed == [],
           """
           These events have no named EventEmail clause and fall to the generic subject:

               #{inspect(unnamed)}

           They would arrive in a customer's inbox titled "#{@email_catch_all_subject}"
           with the body "Event: <event>." — the event name, not what happened.
           Add a named `render/2` clause in cloud/lib/barkpark_cloud/notifications/event_email.ex.
           """
  end

  test "the two catch-all literals are still the catch-alls (keeps the censuses above non-vacuous)" do
    assert render_title(@unknown_event) == @render_catch_all_title,
           "Render's fallback title changed; the render census above now matches nothing " <>
             "and would report clean no matter how many events were unnamed."

    assert email_subject(String.to_atom(@unknown_event)) == @email_catch_all_subject,
           "EventEmail's fallback subject changed; the email census above now matches nothing " <>
             "and would report clean no matter how many events were unnamed."
  end
end
