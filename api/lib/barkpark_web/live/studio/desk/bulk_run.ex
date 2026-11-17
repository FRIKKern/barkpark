defmodule BarkparkWeb.Studio.Desk.BulkRun do
  @moduledoc """
  The work of a desk list's bulk publish and unpublish (`Bulk` holds the
  selection and starts it): what is stored of the ticked documents when an
  action starts, the writes, and the summary in the TanStack Studio's words
  (`lib/bulk.ts`).

  Only `work/6` writes. It takes the page's socket for the dataset and for
  the caller and scope its writes carry (`Shared.hook_opts/1`,
  `Shared.disconnect_opts/1`), and the document type from the selection,
  which the page read from its own URL. Each document goes through
  `Content.publish_document/4` or `Content.unpublish_document/4` on its own,
  so one refusal never stops the rest.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [send_update: 3]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.StudioLive.Shared

  # A running action says how far it is this often, at most.
  @tell_ms 250

  @doc """
  What is stored of each ticked document right now, in the page's dataset
  and scope, as `{draft?, published?}`: one read, when an action starts. A
  document that is gone (deleted since it was ticked) is neither.
  """
  def stored(socket, %{ids: ids, type: type}) do
    %{dataset: dataset, scope: scope} = socket.assigns
    asked = ids ++ Enum.map(ids, &DraftId.draft_id/1)
    found = Content.resolvable_doc_ids(asked, type, dataset, scope)

    Map.new(ids, fn id ->
      {id, {MapSet.member?(found, DraftId.draft_id(id)), MapSet.member?(found, id)}}
    end)
  end

  @doc "The outcome of a document that is gone."
  def gone, do: {:failed, gettext("The document is no longer there")}

  @doc """
  The task's work: the ticked documents, one at a time. `plan` says of each
  what `stored/2` found: `:write` it, `:skipped` (nothing to do), `:gone`.
  Answers `{action, outcomes, written}`, or `{:refused, why}` when the
  references could not be taken out first.
  """
  def work(socket, pane, state, action, plan, cut) do
    dataset = socket.assigns.dataset
    type = state.type
    opts = Shared.hook_opts(socket)
    cut_opts = Shared.disconnect_opts(socket)
    page = self()
    tell = fn at -> send_update(page, PaneComponent, id: pane, bulk_at: at) end

    work =
      PaneComponent.in_locale(fn ->
        with :ok <- disconnect(cut, dataset, cut_opts) do
          # How far it is, a few times a second at most: each word redraws the list.
          {done, _told} =
            plan
            |> Enum.with_index(1)
            |> Enum.map_reduce(nil, fn {{id, what}, at}, told ->
              now = System.monotonic_time(:millisecond)
              due? = is_nil(told) or now - told >= @tell_ms
              if due?, do: tell.(at)

              result =
                case what do
                  :write -> outcome(action, write(action, id, type, dataset, opts))
                  :skipped -> :skipped
                  :gone -> gone()
                end

              {{id, result}, if(due?, do: now, else: told)}
            end)

          written = for {id, :done} <- done, do: id
          {action, Enum.map(done, &elem(&1, 1)), written}
        end
      end)

    work
  end

  defp write(:publish, id, type, dataset, opts),
    do: Content.publish_document(id, type, dataset, opts)

  defp write(:unpublish, id, type, dataset, opts),
    do: Content.unpublish_document(id, type, dataset, opts)

  # The references go first, as the single dialog's: a refusal there stops
  # before anything is unpublished.
  defp disconnect(ids, dataset, opts) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Content.disconnect_references(id, dataset, opts) do
        {:error, {:outside_write_grant, denied}} ->
          {:halt, {:refused, Shared.outside_grant_disconnect_message(denied, "unpublished")}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp outcome(_action, {:ok, _doc}), do: :done
  # It was there when the action started (`stored/2`) and is not now.
  defp outcome(_action, {:error, :not_found}), do: gone()

  defp outcome(:publish, {:error, {wall, details}})
       when wall in [:label_spine, :unknown_tag, :duplicate_of],
       do: {:walled, Shared.format_wall_details(details)}

  defp outcome(_action, {:error, reason}), do: {:failed, reason(reason)}
  defp outcome(_action, _other), do: {:failed, reason(nil)}

  defp reason({:halted, why}) when is_binary(why), do: why
  defp reason(:publish_not_permitted), do: gettext("Your role cannot publish here")
  defp reason(why) when is_binary(why), do: why
  defp reason(_why), do: gettext("Barkpark refused the change")

  @doc """
  What a bulk action did, in the TanStack Studio's words (`bulkSummary`):
  "Published 2 of 3", then what was left alone and why.
  """
  @spec summary(:publish | :unpublish, [term()]) :: %{
          tone: String.t(),
          title: String.t(),
          description: String.t() | nil
        }
  def summary(action, outcomes) do
    total = length(outcomes)
    done = Enum.count(outcomes, &(&1 == :done))
    skipped = Enum.count(outcomes, &(&1 == :skipped))
    walls = for {:walled, why} <- outcomes, do: why
    fails = for {:failed, why} <- outcomes, do: why

    title =
      case action do
        :publish -> gettext("Published %{done} of %{total}", done: done, total: total)
        :unpublish -> gettext("Unpublished %{done} of %{total}", done: done, total: total)
      end

    parts = [
      skipped > 0 && left_alone(action, skipped),
      walls != [] &&
        gettext("%{n} blocked by the publish wall — %{reason}",
          n: length(walls),
          reason: hd(walls)
        ),
      fails != [] && gettext("%{n} failed: %{reason}", n: length(fails), reason: hd(fails))
    ]

    %{
      tone: if(walls != [] or fails != [], do: "critical", else: "positive"),
      title: title,
      description:
        case Enum.filter(parts, & &1) do
          [] -> nil
          said -> Enum.join(said, " ")
        end
    }
  end

  defp left_alone(:publish, n), do: gettext("%{n} had no changes to publish.", n: n)

  defp left_alone(:unpublish, n),
    do: ngettext("%{n} was not published.", "%{n} were not published.", n, n: n)
end
