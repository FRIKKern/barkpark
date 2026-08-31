defmodule BarkparkWeb.Studio.StudioLive.Handlers.Schema do
  @moduledoc """
  Schema-declared document actions (modal action registry) + confirm-modal
  dry-run/real. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias BarkparkWeb.Studio.StudioLive.{DocActions, Shared}

  def schema_action(%{"name" => name}, socket) do
    action = DocActions.find_resolved_doc_action(socket, name)

    case action do
      %{"kind" => "modal"} = a ->
        {:noreply,
         assign(socket,
           confirm_modal: %{
             action: a,
             stage: "initial",
             doc_id: DocActions.doc_id_for_action(socket),
             dataset: socket.assigns[:dataset],
             preview: nil
           }
         )}

      _ ->
        {:noreply, put_flash(socket, :info, "Action #{name} not yet wired")}
    end
  end

  def close_confirm_modal(socket) do
    {:noreply, assign(socket, confirm_modal: nil)}
  end

  def confirm_modal_dryrun(socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset} = modal
      when is_binary(doc_id) and is_binary(dataset) ->
        result = DocActions.dispatch_action(socket, name, doc_id, dataset, :dryrun)
        preview = DocActions.preview_from_result(result)

        {:noreply,
         assign(socket, confirm_modal: Map.merge(modal, %{stage: "dryrun", preview: preview}))}

      _ ->
        {:noreply, socket}
    end
  end

  def confirm_modal_real(socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset}
      when is_binary(doc_id) and is_binary(dataset) ->
        case DocActions.dispatch_action(socket, name, doc_id, dataset, :real) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:info, "#{name} enqueued")
             |> Shared.rebuild_panes()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:error, "#{name} failed: #{DocActions.format_action_error(reason)}")}

          # Catch-all: a handler returning anything other than {:ok, _} /
          # {:error, _} (e.g. :ok, a bare map, nil) used to CaseClauseError
          # here instead of producing a flash.
          other ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:error, "#{name} failed: #{DocActions.format_action_error(other)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end
end
