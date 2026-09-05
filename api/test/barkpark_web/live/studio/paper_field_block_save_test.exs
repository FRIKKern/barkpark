defmodule BarkparkWeb.Studio.PaperFieldBlockSaveTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.PaperFieldBlock

  test "correlated form save preserves its draft until the parent echoes it" do
    block = %{
      "id" => "c-price",
      "type" => "composite",
      "label" => "Price",
      "fields" => [
        %{"name" => "amount", "title" => "Amount", "type" => "string"},
        %{"name" => "request_id", "title" => "Request ID", "type" => "string"}
      ],
      "value" => %{"amount" => "299", "request_id" => "old-field-value"}
    }

    assert {:ok, socket} =
             PaperFieldBlock.update(%{id: "paper-fb-c-price", block: block, if_rev: 7}, socket())

    assert {:noreply, pending_socket} =
             PaperFieldBlock.handle_event(
               "inner-flush",
               %{
                 "request_id" => "field-request-1",
                 "values" => %{"amount" => "399", "request_id" => "real-field-value"}
               },
               socket
             )

    assert_receive {:paper_op,
                    %{
                      "op" => "patch-block",
                      "id" => "c-price",
                      "patch" => %{
                        "value" => %{"amount" => "399", "request_id" => "real-field-value"}
                      },
                      "if_rev" => 7
                    }, "field-request-1"}

    # A refused write renders the old persisted block. The component retains
    # the draft so the browser can retry the complete value on the next View.
    assert {:ok, refused_socket} =
             PaperFieldBlock.update(%{id: "paper-fb-c-price", block: block}, pending_socket)

    assert refused_socket.assigns.value == %{
             "amount" => "399",
             "request_id" => "real-field-value"
           }

    assert refused_socket.assigns.pending_value?

    echoed_block =
      Map.put(block, "value", %{"amount" => "399", "request_id" => "real-field-value"})

    assert {:ok, confirmed_socket} =
             PaperFieldBlock.update(
               %{id: "paper-fb-c-price", block: echoed_block},
               refused_socket
             )

    assert confirmed_socket.assigns.value == %{
             "amount" => "399",
             "request_id" => "real-field-value"
           }

    refute confirmed_socket.assigns.pending_value?
  end

  test "correlated structural save carries the request id and retains the changed list" do
    block = %{
      "id" => "c-keywords",
      "type" => "arrayOf",
      "label" => "Keywords",
      "of" => %{"name" => "keyword", "type" => "string"},
      "value" => ["history"]
    }

    assert {:ok, socket} =
             PaperFieldBlock.update(
               %{id: "paper-fb-c-keywords", block: block, if_rev: 7},
               socket()
             )

    assert {:noreply, pending_socket} =
             PaperFieldBlock.handle_event(
               "inner-array-op",
               %{"action" => "add_row", "request_id" => "array-request-1"},
               socket
             )

    assert_receive {:paper_op,
                    %{
                      "op" => "patch-block",
                      "id" => "c-keywords",
                      "patch" => %{"value" => ["history", ""]},
                      "if_rev" => 7
                    }, "array-request-1"}

    assert {:ok, refused_socket} =
             PaperFieldBlock.update(%{id: "paper-fb-c-keywords", block: block}, pending_socket)

    assert refused_socket.assigns.value == ["history", ""]
    assert refused_socket.assigns.pending_value?
  end

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
  end
end
