defmodule Barkpark.Plugins.OnixEdit.Web.BokbasenLive do
  @moduledoc """
  Admin operations console for Bokbasen publish submissions.

  Phase 7 WI6. Lists every `book` document that carries a `bp_export_status`
  payload, with sortable columns, state + date-range filters, per-row
  Retry/View Document actions, and per-document PubSub subscriptions on
  `bokbasen:document:<doc_id>` for real-time pill updates.

  ## Auth

  Mounted via OnixEdit's `register_routes/1` callback (Goal `barkpark-G3`
  task s4) with `auth: :ops`. The host router's `:plugin_ops`
  live_session uses `BarkparkWeb.LiveAuth.:ops` as its on_mount hook —
  tokens with `"admin"` OR a dedicated `"ops"` permission pass; everything
  else is redirected to `/studio` with a flash. Final mount lives at
  `/admin/onixedit/bokbasen`; the legacy `/admin/bokbasen` URL is kept
  alive by a 301 redirect in `BarkparkWeb.Router`.

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

  # d07 F2 scar-class bound: `load_submissions/1` selects book-type documents in
  # `production` and holds one row per submission in the `all_submissions` assign
  # for the life of the socket. Unbounded, that assign would grow with the total
  # ONIX book count across every workspace, pinning O(total-books) into the
  # LiveView process heap. This is the PAGE SIZE: every read is a single
  # LIMIT/OFFSET window (see `next_page`/`prev_page`), so the heap holds exactly
  # one page no matter how deep the operator pages. Raise deliberately, never remove.
  @page_limit 200

  @impl true
  def mount(_params, _session, socket) do
    # d07 F2 mount gate: mount/3 runs TWICE — once for the discarded
    # disconnected HTTP render, once for the live WebSocket mount. Running
    # `load_submissions/1` unconditionally doubled the DB projection per console
    # open (and the dead render is thrown away). This surface is admin-gated, so
    # no crawler consumes the disconnected HTML — load ONLY on the live mount and
    # subscribe to the loaded rows there; the dead render carries an empty page.
    {submissions, has_next?, subscribed} =
      if connected?(socket) do
        {subs, has_next?} = load_submissions(0)
        subscribed = resubscribe(MapSet.new(), subs)
        {subs, has_next?, subscribed}
      else
        {[], false, MapSet.new()}
      end

    {:ok,
     socket
     |> assign(
       page_title: "Bokbasen Submissions",
       all_submissions: submissions,
       page: 0,
       has_next_page: has_next?,
       sort_field: :last_action_at,
       sort_direction: :desc,
       state_filter: MapSet.new(@all_states),
       date_from: "",
       date_to: "",
       expanded_errors: MapSet.new(),
       all_states: @all_states,
       retryable_states: @retryable_states,
       subscribed: subscribed
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
          # barkpark-zdvi — carry the row's tenancy scope into the retry job
          # so the worker re-reads THIS tenant's book. The admin console lists
          # globally (dataset == "production" across workspaces), so a bare
          # retry without scope could let the worker resolve another
          # workspace's same-id book. `workspace_id`/`project_id` are captured
          # off the loaded Document in `document_to_row/1`; nil-safe via
          # `put_scope_args/2` for legacy rows missing scope.
          args =
            %{
              "document_id" => sub.doc_id,
              "type" => sub.type,
              "dataset" => sub.dataset
            }
            |> PublishWorker.put_scope_args(
              workspace_id: sub.workspace_id,
              project_id: sub.project_id
            )

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

  # PINNED design: OFFSET-based pagination (NOT cursor). The @page_limit cap on
  # `load_submissions/1` bounds the socket heap to one page, but rows past the
  # cap were unreachable. `next_page`/`prev_page` re-run the projection at a new
  # OFFSET, preserving `updated_at desc` order and the per-page bound. The
  # `subscribed` set is the subscription ledger: `resubscribe/2` unsubscribes the
  # outgoing page's doc topics and subscribes the incoming page's, so PubSub
  # subscriptions do NOT leak per socket across navigation.
  def handle_event("next_page", _params, socket) do
    if socket.assigns.has_next_page do
      {:noreply, change_page(socket, socket.assigns.page + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_page", _params, socket) do
    if socket.assigns.page > 0 do
      {:noreply, change_page(socket, socket.assigns.page - 1)}
    else
      {:noreply, socket}
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
                      navigate={book_editor_path(assigns, sub)}
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

      <%= if @page > 0 or @has_next_page do %>
        <nav class="bp-pager" data-test-id="bokbasen-pager" aria-label="Submissions pages">
          <button
            type="button"
            phx-click="prev_page"
            disabled={@page == 0}
            data-test-action="prev-page"
          >
            ← Newer
          </button>
          <span data-test-id="bokbasen-page-number">Page {@page + 1}</span>
          <button
            type="button"
            phx-click="next_page"
            disabled={not @has_next_page}
            data-test-action="next-page"
          >
            Older →
          </button>
        </nav>
      <% end %>
    </div>
    """
  end

  # ---- Helpers ---------------------------------------------------------------

  # Load one @page_limit-sized page (0-based) of the most-recently-updated book
  # submissions. Returns `{rows, has_next_page?}`. The heap bound is per-page:
  # exactly one LIMIT window is ever held, so `all_submissions` never grows with
  # the total book count (d07 F2 scar class) regardless of how deep the operator
  # pages. `has_next_page?` is derived from the RAW row count (before the nil-state
  # reject) so a page whose last rows lack an export status still advertises the
  # next page correctly — never an unbounded `Repo.all`.
  defp load_submissions(page) when is_integer(page) and page >= 0 do
    docs =
      Document
      |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
      |> order_by([d], desc: d.updated_at)
      |> limit(^@page_limit)
      |> offset(^(page * @page_limit))
      |> Repo.all()

    rows =
      docs
      |> Enum.map(&document_to_row/1)
      |> Enum.reject(fn row -> is_nil(row.state) end)

    {rows, length(docs) == @page_limit}
  end

  # Move to `new_page`: re-project at the new OFFSET, hand the subscription
  # ledger to `resubscribe/2` (which unsubscribes the outgoing page's doc topics
  # and subscribes the incoming page's — no per-socket leak), and reset the
  # per-row expanded-error UI state, which is keyed on doc_ids that no longer
  # exist on the new page.
  defp change_page(socket, new_page) do
    {rows, has_next?} = load_submissions(new_page)
    subscribed = resubscribe(socket.assigns.subscribed, rows)

    assign(socket,
      all_submissions: rows,
      page: new_page,
      has_next_page: has_next?,
      subscribed: subscribed,
      expanded_errors: MapSet.new()
    )
  end

  # Reconcile the socket's PubSub subscriptions with the doc_ids on the current
  # page: unsubscribe every topic that is leaving, subscribe every topic that is
  # arriving, leave overlaps untouched. Returns the new subscribed doc_id set.
  # Without this, `mount/3`'s per-doc subscribe would accumulate one leaked
  # subscription per doc_id per page turn for the life of the socket.
  defp resubscribe(%MapSet{} = old_ids, rows) do
    new_ids = rows |> Enum.map(& &1.doc_id) |> MapSet.new()

    old_ids
    |> MapSet.difference(new_ids)
    |> Enum.each(fn doc_id ->
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, "bokbasen:document:#{doc_id}")
    end)

    new_ids
    |> MapSet.difference(old_ids)
    |> Enum.each(fn doc_id ->
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{doc_id}")
    end)

    new_ids
  end

  defp document_to_row(%Document{} = doc) do
    status = BokbasenStatus.read(doc)

    %{
      doc_id: doc.doc_id,
      type: doc.type,
      dataset: doc.dataset,
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
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

  # Scoped deep link (P5 of Scoped-by-URL): on the /w/:ws/p/:proj/admin
  # mount PluginScopeSession carries the scope — link the book editor
  # under the SAME tenant. The flat mount emits the flat form, which the
  # P3 redirect resolves (session scope) — never a dead link either way.
  defp book_editor_path(assigns, sub) do
    with %{slug: ws_slug} when is_binary(ws_slug) <- assigns[:current_workspace],
         %{slug: proj_slug} when is_binary(proj_slug) <- assigns[:current_project] do
      "/w/#{ws_slug}/p/#{proj_slug}/d/#{sub.dataset}/studio/book/#{sub.doc_id}"
    else
      _ -> "/studio/#{sub.dataset}/book/#{sub.doc_id}"
    end
  end
end
