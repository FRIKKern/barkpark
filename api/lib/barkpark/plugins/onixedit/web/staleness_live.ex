defmodule Barkpark.Plugins.OnixEdit.Web.StalenessLive do
  @moduledoc """
  Phase 8 WI4 — admin console for ONIX codelist drift in `book` documents.

  Lists every `book` document in the `production` dataset, classifies its
  codelist refs against the configured current registry issue, and gives
  the operator two actions per row:

    * **Re-validate** — calls `StalenessChecker.revalidate/2` against a
      fresh registry snapshot and shows the diff in a flash. Read-only;
      does not mutate the document.
    * **Mark accepted as-is** — sets `staleness_acknowledged: true` on
      the document's `content` map. Subsequent loads classify the
      document's previously-stale refs as `:acknowledged` (gray pill).

  ## Auth

  Mounted via OnixEdit's `register_routes/1` callback (Goal `barkpark-G3`
  task s4) with `auth: :ops`. The host router's `:plugin_ops`
  live_session uses `BarkparkWeb.LiveAuth.:ops` as its on_mount hook —
  same gate as the sibling Bokbasen console. Tokens without `admin` (or
  the dedicated `ops` permission) redirect to `/studio` with a flash.
  Final mount lives at `/admin/onixedit/staleness` — same URL as before
  the move, the plugin-side path happens to coincide with the host
  scope's path.

  ## Pill colours

  PILL COLOURS ARE INLINED IN THIS FILE BY DESIGN. Phase 8 WI5 will
  extract a shared `StatusPill` helper that the bokbasen + onixedit
  consoles share. WI5 may not be merged yet; until it is, the pill
  colour map below is the source of truth for OnixEdit. When WI5
  lands, the helper takes ownership of the colour map and this LV
  switches to the helper. The colour map MUST stay aligned with the
  WI5 helper so the visual style remains consistent across consoles.
  """

  use BarkparkWeb, :live_view

  import Ecto.Query

  alias Barkpark.Content.Codelists.Codelist
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker
  alias Barkpark.Repo

  @type_default "book"
  @dataset_default "production"
  @default_current_issue "73"

  @impl true
  def mount(_params, _session, socket) do
    current_issue = current_registry_issue()
    books = load_books()
    rows = Enum.map(books, &row_for(&1, current_issue))

    {:ok,
     socket
     |> assign(
       page_title: "OnixEdit Codelist Staleness",
       current_issue: current_issue,
       rows: rows,
       last_diff: nil
     )}
  end

  # ── events ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("revalidate", %{"doc_id" => doc_id}, socket) do
    case Enum.find(socket.assigns.rows, fn r -> r.doc_id == doc_id end) do
      nil ->
        {:noreply, put_flash(socket, :error, "Book #{doc_id} not loaded in this view.")}

      row ->
        registry = current_registry_snapshot()
        diff = StalenessChecker.revalidate(row.doc, registry)

        msg =
          "Re-validated #{doc_id}: " <>
            "#{length(diff.changed)} changed, " <>
            "#{length(diff.removed)} removed, " <>
            "#{length(diff.added)} added"

        {:noreply,
         socket
         |> assign(last_diff: %{doc_id: doc_id, diff: diff})
         |> put_flash(:info, msg)}
    end
  end

  def handle_event("acknowledge", %{"doc_id" => doc_id}, socket) do
    with {:ok, doc} <- fetch_doc(doc_id),
         updated_content <- Map.put(doc.content || %{}, "staleness_acknowledged", true),
         {:ok, updated_doc} <-
           doc
           |> Document.changeset(%{"content" => updated_content})
           |> Repo.update() do
      rows =
        Enum.map(socket.assigns.rows, fn r ->
          if r.doc_id == doc_id do
            row_for(updated_doc, socket.assigns.current_issue)
          else
            r
          end
        end)

      {:noreply,
       socket
       |> assign(rows: rows)
       |> put_flash(:info, "Marked #{doc_id} as accepted as-is.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Book #{doc_id} no longer exists.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Acknowledge failed: #{inspect(cs.errors)}")}
    end
  end

  # ── render ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bp-admin-onixedit-staleness" data-test-id="onixedit-staleness-admin">
      <h1>OnixEdit Codelist Staleness</h1>
      <p class="bp-meta" data-test-id="current-issue">
        Current registry issue: <strong>{@current_issue}</strong>
      </p>

      <%= if Enum.empty?(@rows) do %>
        <p data-test-id="onixedit-staleness-empty">
          No book documents in the production dataset yet.
        </p>
      <% else %>
        <table class="bp-table" data-test-id="onixedit-staleness-table">
          <thead>
            <tr>
              <th>Book title</th>
              <th>Codelist refs</th>
              <th>Ref issue versions</th>
              <th>Current registry version</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @rows do %>
              <tr data-test-doc-id={row.doc_id}>
                <td>
                  <strong>{truncate(row.title, 60)}</strong>
                  <div class="bp-doc-id">{row.doc_id}</div>
                </td>
                <td data-test-codelist-count={row.ref_count}>
                  {row.ref_count}
                  <%= if row.ref_count > 0 do %>
                    <details>
                      <summary>view</summary>
                      <ul class="bp-codelist-list">
                        <%= for ref <- row.refs do %>
                          <li>
                            <code>{ref.path}</code> →
                            <code>{ref.codelist}</code>
                          </li>
                        <% end %>
                      </ul>
                    </details>
                  <% end %>
                </td>
                <td>{ref_issues_summary(row.refs)}</td>
                <td>{@current_issue}</td>
                <td>
                  <span
                    class={"bp-pill " <> pill_class(row.aggregate_status)}
                    data-test-pill={Atom.to_string(row.aggregate_status)}
                  >
                    {Atom.to_string(row.aggregate_status)}
                  </span>
                </td>
                <td>
                  <button
                    type="button"
                    phx-click="revalidate"
                    phx-value-doc_id={row.doc_id}
                    data-test-action="revalidate"
                  >
                    Re-validate
                  </button>
                  <button
                    type="button"
                    phx-click="acknowledge"
                    phx-value-doc_id={row.doc_id}
                    data-test-action="acknowledge"
                    disabled={row.acknowledged}
                  >
                    Mark accepted as-is
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>

      <%= if @last_diff do %>
        <section class="bp-revalidate-diff" data-test-id="last-diff">
          <h2>Last re-validate diff — {@last_diff.doc_id}</h2>
          <p>changed: {length(@last_diff.diff.changed)}</p>
          <p>removed: {length(@last_diff.diff.removed)}</p>
          <p>added: {length(@last_diff.diff.added)}</p>
        </section>
      <% end %>
    </div>
    """
  end

  # ── data loaders ─────────────────────────────────────────────────────

  defp load_books do
    Document
    |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
    |> order_by([d], asc: d.doc_id)
    |> Repo.all()
  end

  defp fetch_doc(doc_id) do
    case Repo.get_by(Document, doc_id: doc_id, type: @type_default, dataset: @dataset_default) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp row_for(%Document{} = doc, current_issue) do
    refs = StalenessChecker.detect_stale(doc, current_issue)
    acknowledged = Map.get(doc.content || %{}, "staleness_acknowledged") == true

    %{
      doc_id: doc.doc_id,
      title: doc.title || "(untitled)",
      doc: doc,
      refs: refs,
      ref_count: length(refs),
      aggregate_status: aggregate_status(refs, acknowledged),
      acknowledged: acknowledged
    }
  end

  defp aggregate_status([], false), do: :current
  defp aggregate_status([], true), do: :acknowledged

  defp aggregate_status(refs, acknowledged) do
    cond do
      acknowledged -> :acknowledged
      Enum.any?(refs, fn r -> r.status == :deprecated end) -> :deprecated
      Enum.any?(refs, fn r -> r.status == :stale end) -> :stale
      true -> :current
    end
  end

  defp current_registry_issue do
    case Repo.aggregate(Codelist, :max, :issue) do
      nil -> @default_current_issue
      "" -> @default_current_issue
      issue when is_binary(issue) -> issue
      _ -> @default_current_issue
    end
  end

  defp current_registry_snapshot do
    Codelist
    |> Repo.all()
    |> Enum.reduce(%{}, fn cl, acc ->
      key = "#{cl.plugin_name}:#{cl.list_id}"

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, %{issue_version: cl.issue, codes: :any})

        %{issue_version: prev} ->
          if cl.issue > prev,
            do: Map.put(acc, key, %{issue_version: cl.issue, codes: :any}),
            else: acc
      end
    end)
  end

  # ── presentation helpers ─────────────────────────────────────────────

  # WI5 will extract these into a shared StatusPill helper. Keep the
  # colour mapping aligned across consoles when refactoring.
  defp pill_class(:current), do: "bg-green-100 text-green-800"
  defp pill_class(:stale), do: "bg-yellow-100 text-yellow-800"
  defp pill_class(:deprecated), do: "bg-red-100 text-red-800"
  defp pill_class(:acknowledged), do: "bg-gray-100 text-gray-800"
  defp pill_class(_), do: "bg-gray-100 text-gray-800"

  defp ref_issues_summary([]), do: "—"

  defp ref_issues_summary(refs) do
    refs
    |> Enum.map(fn r -> r.ref_issue || "(none)" end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) <= n, do: s, else: String.slice(s, 0, n - 1) <> "…"
  end
end
