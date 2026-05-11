defmodule BarkparkWeb.Admin.BokbasenLive do
  @moduledoc """
  Admin operations console for Bokbasen publish submissions.

  Phase 7 WI6. Lists every `book` document that carries a `bp_export_status`
  payload, with sortable columns, state + date-range filters, per-row
  Retry/View Document actions, and per-document PubSub subscriptions on
  `bokbasen:document:<doc_id>` for real-time pill updates.

  ## Auth

  Mounted via the existing `BarkparkWeb.LiveAuth.:admin` `on_mount` hook —
  the same gate that protects `/studio/settings`. Tokens without the
  `"admin"` permission are redirected to `/studio` with a flash. There is
  no separate "operator" role today; the brief flags admin-role refinement
  as a Phase 8 follow-up.

  ## State machine (mirrors WI4 `PublishWorker`)

      pending → staging → staged → polling → accepted
                                          ↘ rejected
                                          ↘ failed
                                          ↘ cancelled
                                          ↘ cannot_cancel

  Retry is enabled only on terminal-error rows (`failed`, `rejected`,
  `cancelled`, `cannot_cancel`). Re-publishing a row in those states
  enqueues a fresh `PublishWorker` job; the unique-keys clause on the
  worker (60 s window keyed on `document_id`) protects against double
  enqueue.
  """

  use BarkparkWeb, :live_view

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status, as: BokbasenStatus
  alias Barkpark.Plugins.OnixEdit.Export.StatusPill
  alias Barkpark.Repo

  @type_default "book"
  @dataset_default "production"

  @all_states ~w(pending staging staged polling accepted rejected failed cancelled cannot_cancel)
  @retryable_states ~w(failed rejected cancelled cannot_cancel)

  @impl true
  def mount(_params, _session, socket) do
    submissions = load_submissions()

    if connected?(socket) do
      Enum.each(submissions, fn sub ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{sub.doc_id}")
      end)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Bokbasen Submissions",
       all_submissions: submissions,
       sort_field: :last_action_at,
       sort_direction: :desc,
       state_filter: MapSet.new(@all_states),
       date_from: "",
       date_to: "",
       expanded_errors: MapSet.new(),
       all_states: @all_states,
       retryable_states: @retryable_states,
       subscribed: subscribed_set(submissions)
     )}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    {sort_field, sort_direction} =
      if socket.assigns.sort_field == field_atom do
        {field_atom, toggle(socket.assigns.sort_direction)}
      else
        {field_atom, :asc}
      end

    {:noreply, assign(socket, sort_field: sort_field, sort_direction: sort_direction)}
  end

  def handle_event("toggle_state_filter", %{"state" => state}, socket) do
    set = socket.assigns.state_filter

    new_set =
      if MapSet.member?(set, state),
        do: MapSet.delete(set, state),
        else: MapSet.put(set, state)

    {:noreply, assign(socket, state_filter: new_set)}
  end

  def handle_event("clear_state_filter", _params, socket) do
    {:noreply, assign(socket, state_filter: MapSet.new(@all_states))}
  end

  def handle_event("set_date_range", %{"date_from" => from, "date_to" => to}, socket) do
    {:noreply, assign(socket, date_from: from, date_to: to)}
  end

  def handle_event("toggle_error", %{"doc_id" => doc_id}, socket) do
    set = socket.assigns.expanded_errors

    new_set =
      if MapSet.member?(set, doc_id),
        do: MapSet.delete(set, doc_id),
        else: MapSet.put(set, doc_id)

    {:noreply, assign(socket, expanded_errors: new_set)}
  end

  def handle_event("retry", %{"doc_id" => doc_id}, socket) do
    case Enum.find(socket.assigns.all_submissions, &(&1.doc_id == doc_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Document not found in current page")}

      sub ->
        if sub.state in @retryable_states do
          args = %{
            "document_id" => sub.doc_id,
            "type" => sub.type,
            "dataset" => sub.dataset
          }

          case args |> PublishWorker.new() |> Oban.insert() do
            {:ok, _job} ->
              {:noreply,
               socket
               |> put_flash(:info, "Retry enqueued for #{sub.doc_id}")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
          end
        else
          {:noreply, put_flash(socket, :error, "Cannot retry from state #{inspect(sub.state)}")}
        end
    end
  end

  @impl true
  def handle_info({:bokbasen_status_update, %{} = status}, socket) do
    submissions =
      Enum.map(socket.assigns.all_submissions, fn sub ->
        if matches_status?(sub, status) do
          Map.merge(sub, status_to_row(status))
        else
          sub
        end
      end)

    {:noreply, assign(socket, all_submissions: submissions)}
  end

  # ---- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_submissions, visible_submissions(assigns))

    ~H"""
    <div class="bp-admin-bokbasen" data-test-id="bokbasen-admin">
      <h1>Bokbasen Submissions</h1>

      <div class="bp-filters" data-test-id="bokbasen-filters">
        <fieldset>
          <legend>State</legend>
          <%= for state <- @all_states do %>
            <label>
              <input
                type="checkbox"
                phx-click="toggle_state_filter"
                phx-value-state={state}
                checked={MapSet.member?(@state_filter, state)}
              />
              <span data-test-state-filter={state}>{state}</span>
            </label>
          <% end %>
          <button type="button" phx-click="clear_state_filter">Reset</button>
        </fieldset>

        <form phx-change="set_date_range">
          <label>
            From <input type="date" name="date_from" value={@date_from} />
          </label>
          <label>
            To <input type="date" name="date_to" value={@date_to} />
          </label>
        </form>
      </div>

      <%= if Enum.empty?(@all_submissions) do %>
        <p data-test-id="bokbasen-empty">No Bokbasen submissions yet.</p>
      <% else %>
        <%= if Enum.empty?(@visible_submissions) do %>
          <p data-test-id="bokbasen-no-matches">No submissions match your filters.</p>
        <% else %>
          <table class="bp-table" data-test-id="bokbasen-table">
            <thead>
              <tr>
                <th>
                  <button type="button" phx-click="sort" phx-value-field="title">
                    Title{sort_marker(@sort_field, @sort_direction, :title)}
                  </button>
                </th>
                <th>
                  <button type="button" phx-click="sort" phx-value-field="state">
                    State{sort_marker(@sort_field, @sort_direction, :state)}
                  </button>
                </th>
                <th>
                  <button type="button" phx-click="sort" phx-value-field="submission_id">
                    Submission ID{sort_marker(@sort_field, @sort_direction, :submission_id)}
                  </button>
                </th>
                <th>
                  <button type="button" phx-click="sort" phx-value-field="last_action_at">
                    Last action{sort_marker(@sort_field, @sort_direction, :last_action_at)}
                  </button>
                </th>
                <th>Last error</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for sub <- @visible_submissions do %>
                <tr data-test-doc-id={sub.doc_id}>
                  <td>{truncate(sub.title, 50)}</td>
                  <td>
                    <span
                      class={"bp-pill " <> pill_color(sub.state)}
                      data-test-pill={sub.state}
                    >
                      {sub.state || "(none)"}
                    </span>
                  </td>
                  <td>{sub.submission_id || "—"}</td>
                  <td>{format_dt(sub.last_action_at)}</td>
                  <td>
                    <%= if sub.last_error do %>
                      <button
                        type="button"
                        phx-click="toggle_error"
                        phx-value-doc_id={sub.doc_id}
                      >
                        {error_summary(sub.last_error, sub.doc_id, @expanded_errors)}
                      </button>
                    <% else %>
                      —
                    <% end %>
                  </td>
                  <td>
                    <%= if sub.state in @retryable_states do %>
                      <button
                        type="button"
                        phx-click="retry"
                        phx-value-doc_id={sub.doc_id}
                        data-test-action="retry"
                      >
                        Retry
                      </button>
                    <% else %>
                      <button type="button" disabled data-test-action="retry-disabled">
                        Retry
                      </button>
                    <% end %>
                    <.link
                      navigate={"/studio/#{sub.dataset}/book/#{sub.doc_id}"}
                      data-test-action="view"
                    >
                      View Document
                    </.link>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---- Helpers ---------------------------------------------------------------

  defp load_submissions do
    Document
    |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
    |> Repo.all()
    |> Enum.map(&document_to_row/1)
    |> Enum.reject(fn row -> is_nil(row.state) end)
  end

  defp document_to_row(%Document{} = doc) do
    status = BokbasenStatus.read(doc)

    %{
      doc_id: doc.doc_id,
      type: doc.type,
      dataset: doc.dataset,
      title: doc.title,
      state: Map.get(status, "state"),
      submission_id: submission_id_of(status),
      last_action_at: parse_dt(Map.get(status, "updated_at")),
      last_error: Map.get(status, "last_error")
    }
  end

  defp status_to_row(status) when is_map(status) do
    %{
      state: Map.get(status, "state"),
      submission_id: submission_id_of(status),
      last_action_at: parse_dt(Map.get(status, "updated_at")),
      last_error: Map.get(status, "last_error")
    }
  end

  defp submission_id_of(status) when is_map(status) do
    Map.get(status, "submission_id") || Map.get(status, "bokbasen_submission_id")
  end

  defp matches_status?(%{doc_id: doc_id}, %{} = status) do
    cond do
      Map.get(status, "doc_id") == doc_id -> true
      Map.get(status, "document_id") == doc_id -> true
      true -> false
    end
  end

  defp visible_submissions(assigns) do
    assigns.all_submissions
    |> Enum.filter(&pass_state?(&1, assigns.state_filter))
    |> Enum.filter(&pass_date?(&1, assigns.date_from, assigns.date_to))
    |> Enum.sort_by(&sort_key(&1, assigns.sort_field), sort_dir(assigns.sort_direction))
  end

  defp pass_state?(_row, nil), do: true

  defp pass_state?(%{state: state}, %MapSet{} = filter) do
    cond do
      MapSet.size(filter) == length(@all_states) -> true
      is_nil(state) -> false
      true -> MapSet.member?(filter, state)
    end
  end

  defp pass_date?(_row, "", ""), do: true

  defp pass_date?(%{last_action_at: nil}, from, to) when from != "" or to != "", do: false

  defp pass_date?(%{last_action_at: %DateTime{} = dt}, from, to) do
    pass_from?(dt, from) and pass_to?(dt, to)
  end

  defp pass_date?(_row, _from, _to), do: true

  defp pass_from?(_dt, ""), do: true

  defp pass_from?(dt, from) do
    case Date.from_iso8601(from) do
      {:ok, date} -> Date.compare(DateTime.to_date(dt), date) != :lt
      _ -> true
    end
  end

  defp pass_to?(_dt, ""), do: true

  defp pass_to?(dt, to) do
    case Date.from_iso8601(to) do
      {:ok, date} -> Date.compare(DateTime.to_date(dt), date) != :gt
      _ -> true
    end
  end

  defp sort_key(row, :last_action_at) do
    case row.last_action_at do
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp sort_key(row, :title), do: row.title || ""
  defp sort_key(row, :state), do: row.state || ""
  defp sort_key(row, :submission_id), do: row.submission_id || ""
  defp sort_key(_, _), do: ""

  defp sort_dir(:asc), do: :asc
  defp sort_dir(:desc), do: :desc

  defp toggle(:asc), do: :desc
  defp toggle(:desc), do: :asc

  defp sort_marker(field, :asc, field), do: " ▲"
  defp sort_marker(field, :desc, field), do: " ▼"
  defp sort_marker(_, _, _), do: ""

  defp pill_color(state), do: StatusPill.color_class(state)

  defp truncate(nil, _), do: ""

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) <= n, do: s, else: String.slice(s, 0, n - 1) <> "…"
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_dt(other) when is_binary(other), do: other

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp error_summary(nil, _doc_id, _set), do: "—"

  defp error_summary(err, doc_id, set) do
    expanded? = MapSet.member?(set, doc_id)

    text =
      case err do
        %{"type" => t, "message" => m} when is_binary(m) and m != "" -> "#{t}: #{m}"
        %{"type" => t, "summary" => s} -> "#{t}: #{s}"
        %{"message" => m} when is_binary(m) and m != "" -> m
        %{"type" => t} -> t
        _ -> inspect(err)
      end

    if expanded? do
      text
    else
      truncate(text, 60)
    end
  end

  defp subscribed_set(subs) do
    subs
    |> Enum.map(& &1.doc_id)
    |> MapSet.new()
  end
end
