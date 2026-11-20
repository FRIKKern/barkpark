defmodule BarkparkWeb.Studio.DeskDocStatusPhoneStackTest do
  @moduledoc """
  task-7c69293055e0f411: on a touch phone under 390 px, three or more others
  in the document left the header's pills 37 px wide at 360 (three avatars
  beside the close, the pills and three 44 px buttons). From three others
  on, the stack there is a counter and the last avatar, so the pills keep
  their 44 px. Wider, and with a mouse, it is TanStack's stack of three.
  The browser half (every control inside the header, none overlapping, at
  360 and 390 with one to five others) was checked in Chrome.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.Desk.DocStatus

  defp people(n),
    do:
      for(i <- 1..n, do: %{name: "Person #{i}", color: "var(--dk-avatar-#{i})", user_id: "u#{i}"})

  defp stack(n) do
    html =
      render_component(&DocStatus.chips/1,
        doc: %{doc_id: "d"},
        draft?: true,
        published?: true,
        presences: people(n)
      )

    doc = LazyHTML.from_fragment(html)

    avatars =
      doc
      |> LazyHTML.query(".p-avatars > .p-avatar")
      |> Enum.map(fn a ->
        {a |> LazyHTML.attribute("class") |> hd(), a |> LazyHTML.text() |> String.trim()}
      end)

    {html, avatars}
  end

  test "two others: two avatars, and no phone counter" do
    {_html, avatars} = stack(2)
    assert avatars == [{"p-avatar", "P1"}, {"p-avatar", "P2"}]
  end

  test "three others: the phone counter says two, before the three avatars" do
    {_html, avatars} = stack(3)

    assert avatars == [
             {"p-avatar more p-avatar-phone", "2"},
             {"p-avatar", "P1"},
             {"p-avatar", "P2"},
             {"p-avatar", "P3"}
           ]
  end

  test "five others: the phone counter says four, the wide counter three" do
    {_html, avatars} = stack(5)

    assert avatars == [
             {"p-avatar more p-avatar-phone", "4"},
             {"p-avatar more", "3"},
             {"p-avatar", "P4"},
             {"p-avatar", "P5"}
           ]
  end

  test "under 390 px on touch the stack is the phone counter and the last avatar" do
    {html, _avatars} = stack(3)

    assert html =~ ".dk .dk-chips .p-avatar.more.p-avatar-phone { display: none; }"

    [_, phone] = String.split(html, "@media (max-width: 389px) and (pointer: coarse) {", parts: 2)
    phone = phone |> String.split("}\n      }", parts: 2) |> hd()

    assert phone =~
             ".dk .dk-chips .p-avatars:has(> .p-avatar-phone) > .p-avatar:not(:last-child) { display: none; }"

    assert phone =~
             ".dk .dk-chips .p-avatars > .p-avatar.more.p-avatar-phone { display: inline-grid; }"
  end
end
