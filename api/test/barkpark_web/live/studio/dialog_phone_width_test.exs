defmodule BarkparkWeb.Studio.DialogPhoneWidthTest do
  @moduledoc """
  task-0388184c398d0c12: at 375px the delete confirmation (480px) and the
  document history panel (520px) were wider than the phone, centred, and so
  clipped on both sides — "Slett" and every "Gjenopprett" off-screen. Their
  siblings already cap at the viewport minus a 24px gutter; these two did not.
  Every centred Studio dialog rule that sets a fixed px width must cap it.
  Reads the shipped stylesheet; the layout is checked in a browser.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  defp rule!(css, selector) do
    [_, body] = Regex.run(~r/\n    #{Regex.escape(selector)} \{([^}]*)\}/, css)
    body
  end

  test "the delete and history dialogs never exceed the viewport" do
    css = File.read!(@root)

    assert rule!(css, ".delete-modal") =~ "width: min(480px, calc(100vw - 24px))"
    assert rule!(css, ".history-modal") =~ "width: min(520px, calc(100vw - 24px))"
  end

  test "no centred dialog rule pairs a fixed px width with no viewport cap" do
    css = File.read!(@root)

    offenders =
      ~r/\n    (\.[a-z-]+) \{([^}]*)\}/
      |> Regex.scan(css)
      |> Enum.filter(fn [_, _sel, body] ->
        body =~ "translate(-50%, -50%)" and body =~ ~r/(?<![-\w])width:\s*\d+px/ and
          not (body =~ ~r/max-width:\s*min\(/)
      end)
      |> Enum.map(fn [_, sel, _] -> sel end)

    assert offenders == [], "uncapped centred dialogs: #{inspect(offenders)}"
  end
end
