defmodule BarkparkWeb.EditorPost do
  @moduledoc """
  A post of the Studio editor form sent by hand in a test, as the page's own
  form sends it: naming the document the editor holds
  (`BarkparkWeb.Studio.StudioLive.PostIdentity`, task-8908b6e031268f77).

  The server writes nothing for a post without that name. A test that sends
  `autosave` or `save` by event name, to test something else about the save,
  sends it through here, so what it asserts is still decided by the code it
  is about. A post that already carries the key keeps it.
  """

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc "`params` with the name of the document `view`'s editor holds now."
  def named(view, params \\ %{}) when is_map(params) do
    open = PostIdentity.of(:sys.get_state(view.pid).socket)

    params
    |> Map.put_new(PostIdentity.key(), open)
    |> Map.put_new(PostIdentity.end_key(), open)
  end

  @doc "A `phx-change` of the editor form."
  def change(view, params), do: render_change(view, "autosave", named(view, params))

  @doc "A `phx-submit` of the editor form."
  def submit(view, params \\ %{}), do: render_submit(view, "save", named(view, params))

  @doc "`autosave` or `save` pushed as a hook pushes it."
  def hook(view, event, params) when event in ["autosave", "save"],
    do: render_hook(view, event, named(view, params))

  @doc "`save` sent as a click sends it."
  def click(view, params), do: render_click(view, "save", named(view, params))
end
