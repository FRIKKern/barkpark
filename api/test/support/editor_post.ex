defmodule BarkparkWeb.EditorPost do
  @moduledoc """
  A post of the Studio editor form sent by hand in a test, as the page's own
  form sends it: naming the document the form on the page was drawn for
  (`BarkparkWeb.Studio.StudioLive.PostIdentity`, task-8908b6e031268f77).

  The server writes nothing for a post without that name. A test that sends
  `autosave` or `save` by event name, to test something else about the save,
  sends it through here.

  The name is read from the rendered page, never from the socket: a form
  that does not carry it, or an event built without it, must fail the test
  that sends it. With no editor form on the page there is nothing to read
  and `marks/1` raises. A post that was on its way before the form went
  takes the marks read while the form was there (`named/3`).
  """

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc """
  What the editor form on `view`'s page carries: the form tag's value and
  its last child's, under their params keys. Raises when the page has no
  editor form or the form has no name.
  """
  def marks(view) do
    html = render(view)

    with [_, form] <- Regex.run(~r/<form\b([^>]*\sid="editor-form"[^>]*)>/, html),
         [_, attr] <- Regex.run(~r/\sphx-value-_bp_doc="([^"]*)"/, form),
         [_, last] <-
           Regex.run(~r/<input\b[^>]*\sname="_bp_doc_end"[^>]*\svalue="([^"]*)"/, html) do
      %{PostIdentity.key() => unescape(attr), PostIdentity.end_key() => unescape(last)}
    else
      _ ->
        raise ArgumentError,
              "the page has no #editor-form that names its document " <>
                "(phx-value-_bp_doc on the form, _bp_doc_end as its last child)"
    end
  end

  @doc "`params` as the form on the page sends them; `marks` from an earlier `marks/1`."
  def named(view, params \\ %{}, marks \\ nil) when is_map(params),
    do: Map.merge(marks || marks(view), params)

  @doc "A `phx-change` of the editor form."
  def change(view, params), do: render_change(view, "autosave", named(view, params))

  @doc "A `phx-submit` of the editor form."
  def submit(view, params \\ %{}), do: render_submit(view, "save", named(view, params))

  @doc "`autosave` or `save` pushed as a hook pushes it."
  def hook(view, event, params, marks \\ nil) when event in ["autosave", "save"],
    do: render_hook(view, event, named(view, params, marks))

  @doc "`save` sent as a click sends it."
  def click(view, params, marks \\ nil),
    do: render_click(view, "save", named(view, params, marks))

  defp unescape(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
