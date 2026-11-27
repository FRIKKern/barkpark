defmodule BarkparkWeb.Studio.StudioLive.RejoinForm do
  @moduledoc """
  The form generation a page drew, kept across a socket rejoin
  (task-b656db94cc1dbd17).

  A widget's wrapper id carries the form generation once it is above 0
  (`FieldInputs`' `doc_wrap_id`), so a form the socket drew again (another
  editor's save, a paste) draws its widgets anew. A new socket starts at
  generation 0: after a rejoin the wrapper ids differed from the page's,
  LiveView put an editor drawn from the store in place of the page's, and
  the words typed while the socket was down were gone, with no banner.

  The page sends what its form shows on each join (`_bp_form`, from
  `#editor-form`'s `phx-value-_bp_doc` and `data-bp-form-gen`; bp-array-focus.js
  `BarkparkFormConnectParams`). A socket that mounted as a rejoin draws that
  generation for the document it loads, so the wrapper ids are the page's
  and it keeps its editors (`TextConfirmed` reads their next post). The
  page's value only picks wrapper ids: it is taken only for the document
  the socket loaded itself (`PostIdentity`), never to choose one.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @key "_bp_form"
  @max_gen 100_000

  @doc "The connect params key the page sends its form under."
  def key, do: @key

  @doc """
  The page's form from the connect params of a rejoin: `{doc, gen}`, or
  nil (a first join, no form, or a value that is not one).
  """
  def from_params(%{@key => %{"doc" => doc, "gen" => gen}} = params)
      when is_binary(doc) and byte_size(doc) <= 2048 and (is_binary(gen) or is_integer(gen)) do
    with true <- BarkparkWeb.Studio.DeskLive.rejoin?(params),
         {n, ""} when n >= 0 and n <= @max_gen <- Integer.parse(to_string(gen)) do
      {doc, n}
    else
      _ -> nil
    end
  end

  def from_params(_params), do: nil

  @doc """
  At the rejoin's load: the page's generation, when the page's form was
  drawn for the document the socket loaded. Taken once.
  """
  def loaded(socket) do
    page = socket.assigns[:editor_rejoin_form]
    socket = assign(socket, editor_rejoin_form: nil)

    case page do
      {doc, gen} when is_binary(doc) ->
        if doc == PostIdentity.of(socket), do: assign(socket, editor_form_gen: gen), else: socket

      _ ->
        socket
    end
  end

  @doc "Dropped without being taken (a load that is not the rejoin's)."
  def forget(socket), do: assign(socket, editor_rejoin_form: nil)
end
