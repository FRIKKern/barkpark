defmodule BarkparkWeb.Studio.PaperEditor.TerminalEditorFormTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "chrome changes are presence-aware and preserve untouched metadata" do
    terminal = terminal(%{"title" => "Shell", "footer" => "q quit", "live" => false})

    assert Blocks.validate_block_patch(terminal, %{
             "title" => " New shell ",
             "footer" => "",
             "live" => "true"
           }) ==
             {:ok, %{"title" => " New shell ", "footer" => "", "live" => true}}

    assert terminal["custom"] == %{"kept" => true}
    assert terminal["children"] == [paragraph("body")]
  end

  test "reader-equivalent chrome submissions preserve absent nil numeric and raw live shapes" do
    for {terminal, params} <- [
          {terminal(%{}), %{"title" => "", "footer" => "", "live" => "false"}},
          {terminal(%{"title" => nil, "footer" => nil, "live" => nil}),
           %{"title" => "", "footer" => "", "live" => "false"}},
          {terminal(%{"title" => 7, "footer" => 2.5, "live" => "live"}),
           %{"title" => "7", "footer" => "2.5", "live" => "true"}},
          {terminal(%{"title" => %{"opaque" => true}, "live" => "garbage"}),
           %{"title" => "", "live" => "false"}}
        ] do
      assert Blocks.validate_block_patch(terminal, params) == {:ok, %{}}
      assert Blocks.build_block_patch(terminal, params) == %{}
    end
  end

  test "live accepts only exact boolean wire values and changes only effective truth" do
    assert Blocks.validate_block_patch(terminal(%{"live" => true}), %{"live" => "false"}) ==
             {:ok, %{"live" => false}}

    assert Blocks.validate_block_patch(terminal(%{"live" => "true"}), %{"live" => "true"}) ==
             {:ok, %{}}

    assert Blocks.validate_block_patch(terminal(%{"live" => "live"}), %{"live" => "true"}) ==
             {:ok, %{}}

    for malformed <- ["on", "TRUE", "", true, false, nil, %{}] do
      assert Blocks.validate_block_patch(terminal(), %{"live" => malformed}) ==
               {:error, :invalid_terminal_form}
    end
  end

  test "submitted title and footer values must be exact strings" do
    for {field, malformed} <- [
          {"title", nil},
          {"title", 7},
          {"title", %{}},
          {"footer", false},
          {"footer", []}
        ] do
      assert Blocks.validate_block_patch(terminal(), %{field => malformed}) ==
               {:error, :invalid_terminal_form}

      assert Blocks.build_block_patch(terminal(), %{field => malformed}) == %{}
    end
  end

  test "strict canonical body rejects legacy dual and malformed shapes without a patch" do
    for malformed <- [
          Map.delete(terminal(), "children"),
          terminal(%{"children" => nil}),
          terminal(%{"children" => "opaque"}),
          terminal(%{"blocks" => []}),
          terminal(%{"blocks" => [paragraph("shadow")]})
        ] do
      assert Blocks.validate_block_patch(malformed, %{"title" => "Changed"}) ==
               {:error, :malformed_terminal}

      assert Blocks.build_block_patch(malformed, %{"title" => "Changed"}) == %{}
    end
  end

  test "empty canonical body accepts one strictly fenced paragraph add" do
    empty = terminal(%{"children" => []})

    params = %{
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "new-child",
      "terminal-action" => "add"
    }

    assert Blocks.validate_block_patch(empty, params) ==
             {:ok,
              %{
                "children" => [
                  %{
                    "id" => "new-child",
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "value" => ""}]
                  }
                ]
              }}

    assert Blocks.resolve_block_form([empty], Map.put(params, "block_id", "terminal")) ==
             {:ok,
              %{
                "op" => "patch-block",
                "id" => "terminal",
                "patch" => Blocks.build_block_patch(empty, params)
              }}
  end

  test "add refuses nonempty bodies, stale counts, malformed IDs and unexpected wire" do
    valid = %{
      "terminal-child-count" => "0",
      "terminal-new-child-id" => "new-child",
      "terminal-action" => "add"
    }

    invalid_cases = [
      {terminal(), valid},
      {terminal(%{"children" => []}), Map.put(valid, "terminal-child-count", "1")},
      {terminal(%{"children" => []}), Map.put(valid, "terminal-new-child-id", "   ")},
      {terminal(%{"children" => []}), Map.put(valid, "terminal-action", "remove:any")},
      {terminal(%{"children" => []}), Map.put(valid, "terminal-extra", "opaque")}
    ]

    for {block, params} <- invalid_cases do
      assert Blocks.validate_block_patch(block, params) == {:error, :invalid_terminal_form}
      assert Blocks.build_block_patch(block, params) == %{}
    end
  end

  test "missing or unrelated form wire is rejected by the trusted resolver boundary" do
    terminal = terminal()

    assert Blocks.validate_block_patch(terminal, %{}) == {:error, :invalid_terminal_form}

    assert Blocks.validate_block_patch(terminal, %{"unrelated" => "value"}) ==
             {:error, :invalid_terminal_form}

    assert Blocks.resolve_block_form([terminal], %{"block_id" => "terminal"}) ==
             {:error, {:source_validation, :invalid_terminal_form}}
  end

  defp terminal(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "terminal",
        "type" => "terminal",
        "children" => [paragraph("body")],
        "custom" => %{"kept" => true}
      },
      overrides
    )
  end

  defp paragraph(id),
    do: %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Body"}]
    }
end
