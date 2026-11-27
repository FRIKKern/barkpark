defmodule BarkparkWeb.PageSeen do
  @moduledoc """
  The editor form's `_bp_seen` as the page's bp-array-focus.js keeps it,
  for a LiveViewTest view, which runs no JS.

  The hidden input is `phx-update="ignore"`: a post through LiveViewTest
  carries its first render forever. The page instead takes each digest the
  server pushes with `bp:form-confirmed` (a post the store holds, a redraw
  of a top-level rich text editor): `onConfirmed` → `takeOk`, a string of
  16 lower-case hex characters, the last push winning. `seen/1` does the
  same, per view, so a test posts the `ok` a real page would
  (task-a368aa61eb491d9f).

  Only `bp:form-confirmed` is taken. The page takes the `ok` beside a
  pushed value (`bp:form-born`, `bp:form-remote-values`) only while the
  field shows that value, which a view without JS cannot tell. `seen/1`
  takes the pushes out of the test's mailbox: an `assert_push_event` on
  `bp:form-confirmed` after it finds none.
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  @ok_digest ~r/\A[0-9a-f]{16}\z/

  @doc "The page's `_bp_seen` now: the form's first render, then every pushed digest taken."
  def seen(%{pid: pid, proxy: {ref, _topic, _}} = view) do
    seen = take_pushed(ref, Process.get({__MODULE__, pid}) || drawn(view))
    Process.put({__MODULE__, pid}, seen)
    seen
  end

  @doc "`seen/1` as the hidden input's JSON value."
  def json(view), do: Jason.encode!(seen(view))

  @doc "`seen` with each digest of `oks` taken as `takeOk` takes it."
  def take(seen, oks) when is_map(oks) do
    Enum.reduce(oks, seen, fn {name, ok}, seen ->
      if is_binary(ok) and Regex.match?(@ok_digest, ok) do
        ok_map = if is_map(seen["ok"]), do: seen["ok"], else: %{}
        Map.put(seen, "ok", Map.put(ok_map, name, ok))
      else
        seen
      end
    end)
  end

  def take(seen, _oks), do: seen

  defp drawn(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
  end

  defp take_pushed(ref, seen) do
    receive do
      {^ref, {:push_event, "bp:form-confirmed", %{oks: oks}}} -> take_pushed(ref, take(seen, oks))
    after
      0 -> seen
    end
  end
end
