defmodule BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues do
  @moduledoc """
  Another editor's save, told to the field this tab is resting in
  (task-e6ef964ac2e41d5a).

  A LiveView patch never sets the value of the focused input. So when another
  editor saved the field this tab had focused, the tab kept showing the old
  text, and its next keystroke posted that text back over the other's words.

  `push/3` sends the page each changed text field: its new value and the value
  the page showed before (`bp:form-remote-values`). bp-array-focus.js sets the
  focused input only while it still shows exactly the old value: anything else
  is typing the page has not sent yet, and stays. It writes nothing; the store
  is untouched.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  @event "bp:form-remote-values"

  @doc """
  Tells the page of each top-level text field that differs between `old_form`
  and `new_form`, with the value it showed before.
  """
  def push(socket, old_form, new_form) do
    values =
      for {key, new} <- new_form,
          is_binary(key) and is_binary(new),
          old = Map.get(old_form, key),
          is_binary(old) and old != new,
          into: %{},
          do: {"doc[#{key}]", %{value: new, was: old}}

    if values == %{}, do: socket, else: push_event(socket, @event, %{values: values})
  end
end
