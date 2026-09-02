defmodule Barkpark.DeploymentLiteralsTest do
  @moduledoc """
  gh-9531 residual (task-eeabfd9bf3ed8371): the api's three frozen DEPLOYMENT
  values — the Anthropic-compatible Messages endpoint shared by the tier-2 judge
  and the Studio chat titler, and the ONIX RecordReference host namespace — are
  read at CALL time, default to the historical literals, and FAIL CLOSED on a
  malformed configured value.

  The endpoint cases assert on the URL that reaches the ADAPTER, not on the
  resolver alone: the defect was that the wire kept the compile-time literal
  while every neighbouring knob was configurable, so the wire is what has to
  prove the fix.

  `async: false` and every key restored: these are application-env reads.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.StudioChat.Titles
  alias Barkpark.Tasks.Judge

  # Both fakes report the URL they were handed and then answer with a canned
  # 200, so one adapter proves both halves: where the call went, and that it
  # still parses.
  defmodule UrlSpy do
    def post(url, _body, _headers) do
      send(Application.get_env(:barkpark, :deployment_literals_test_pid), {:posted_to, url})

      {:ok, 200,
       %{
         "content" => [
           %{
             "type" => "text",
             "text" => Application.get_env(:barkpark, :deployment_literals_test_reply)
           }
         ]
       }}
    end
  end

  @judge_keys [
    :judge_http_adapter,
    :anthropic_api_key,
    :anthropic_api_url,
    :studio_chat_title_http_adapter,
    :deployment_literals_test_pid,
    :deployment_literals_test_reply
  ]

  setup do
    previous = Map.new(@judge_keys, &{&1, Application.get_env(:barkpark, &1)})
    onix_previous = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit)

    Application.put_env(:barkpark, :deployment_literals_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:barkpark, key)
        {key, value} -> Application.put_env(:barkpark, key, value)
      end)

      case onix_previous do
        nil -> Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit)
        value -> Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit, value)
      end
    end)

    :ok
  end

  defp put_api_url(value), do: Application.put_env(:barkpark, :anthropic_api_url, value)

  defp put_onix_host(value),
    do: Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit, dataset_host: value)

  defp arm_judge do
    Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
    Application.put_env(:barkpark, :judge_http_adapter, UrlSpy)

    Application.put_env(
      :barkpark,
      :deployment_literals_test_reply,
      ~s({"relation":"distinct","confidence":0.8,"reason":"different"})
    )
  end

  defp arm_titles do
    Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, UrlSpy)
    Application.put_env(:barkpark, :deployment_literals_test_reply, ~s({"title":"API title"}))
  end

  defp task_pair do
    {%{
       title: "add rate limiting",
       description: "throttle writes",
       parent: "e1",
       lifecycle: "open"
     },
     %{
       title: "add rate limiting",
       description: "throttle writes",
       parent: "e2",
       lifecycle: "open"
     }}
  end

  describe "the Anthropic endpoint (3) — judge" do
    test "unconfigured is the vendor URL" do
      assert Application.get_env(:barkpark, :anthropic_api_url) == nil
      assert Judge.endpoint() == "https://api.anthropic.com/v1/messages"
      assert Judge.endpoint() == Judge.default_endpoint()
    end

    test "the wire uses the vendor URL when nothing is configured" do
      arm_judge()
      {a, b} = task_pair()

      assert {:ok, %{relation: "distinct"}} = Judge.judge(a, b)
      assert_received {:posted_to, "https://api.anthropic.com/v1/messages"}
    end

    test "a configured gateway is what the wire actually gets" do
      arm_judge()
      put_api_url("https://gateway.internal/v1/messages")
      {a, b} = task_pair()

      assert Judge.endpoint() == "https://gateway.internal/v1/messages"
      assert {:ok, %{relation: "distinct"}} = Judge.judge(a, b)
      assert_received {:posted_to, "https://gateway.internal/v1/messages"}
    end

    test "FAILS CLOSED on a malformed URL" do
      for bad <- [
            "api.anthropic.com/v1/messages",
            "ftp://gateway.internal/v1/messages",
            "https:///v1/messages",
            "https://gateway.internal/v1/mess ages",
            "https://gateway.internal/v1/messages\r\nX-Evil: 1",
            "",
            :vendor
          ] do
        put_api_url(bad)
        assert_raise ArgumentError, ~r/invalid Anthropic API URL/, fn -> Judge.endpoint() end
      end
    end
  end

  describe "the Anthropic endpoint (3) — Studio chat titles" do
    test "unconfigured is the vendor URL, and it is the SAME key the judge reads" do
      assert Titles.endpoint() == "https://api.anthropic.com/v1/messages"
      assert Titles.endpoint() == Titles.default_endpoint()

      put_api_url("https://gateway.internal/v1/messages")
      assert Titles.endpoint() == Judge.endpoint()
    end

    test "the wire uses the vendor URL when nothing is configured" do
      arm_titles()

      assert Titles.generate("summarize me") == "API title"
      assert_received {:posted_to, "https://api.anthropic.com/v1/messages"}
    end

    test "a configured gateway is what the wire actually gets" do
      arm_titles()
      put_api_url("https://gateway.internal/v1/messages")

      assert Titles.generate("summarize me") == "API title"
      assert_received {:posted_to, "https://gateway.internal/v1/messages"}
    end

    test "FAILS CLOSED on a malformed URL" do
      for bad <- ["gateway.internal", "ftp://gateway.internal", "", 42] do
        put_api_url(bad)
        assert_raise ArgumentError, ~r/invalid Anthropic API URL/, fn -> Titles.endpoint() end
      end
    end
  end

  describe "the ONIX RecordReference host (4)" do
    @book %{"_publishedId" => "p1", "title" => %{"titleText" => "A Book"}}

    test "unconfigured emits the historical namespace" do
      assert Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit) == nil
      assert Export.dataset_host() == "barkpark.cloud"
      assert Export.dataset_host() == Export.default_dataset_host()
      assert Export.record_reference("p1") == "barkpark.cloud:p1"
      assert Export.record_reference("drafts.p1") == "barkpark.cloud:p1"

      assert IO.iodata_to_binary(Export.to_xml(@book)) =~
               "<RecordReference>barkpark.cloud:p1</RecordReference>"
    end

    test "a configured host reaches the emitted XML — the no-call-site-passes-it path" do
      put_onix_host("gyldendal.no")

      assert Export.dataset_host() == "gyldendal.no"
      assert Export.record_reference("p1") == "gyldendal.no:p1"

      # `to_xml/2` with NO :dataset_host opt is what every real caller does
      # (the export controller and the Bokbasen publish worker both pass none),
      # so this is the assertion the defect actually lived behind.
      assert IO.iodata_to_binary(Export.to_xml(@book)) =~
               "<RecordReference>gyldendal.no:p1</RecordReference>"
    end

    test "the per-call opt still wins over the configured default" do
      put_onix_host("gyldendal.no")

      assert Export.record_reference("p1", "other.host") == "other.host:p1"

      assert IO.iodata_to_binary(Export.to_xml(@book, dataset_host: "other.host")) =~
               "<RecordReference>other.host:p1</RecordReference>"
    end

    test "FAILS CLOSED on a malformed host" do
      for bad <- [
            "https://gyldendal.no",
            "gyldendal.no:4000",
            "gyldendal no",
            "GYLDENDAL.no",
            "gyldendal.no/",
            "gyldendal.no.",
            "gyldendal",
            "",
            :gyldendal
          ] do
        put_onix_host(bad)
        assert_raise ArgumentError, ~r/invalid ONIX dataset host/, fn -> Export.dataset_host() end

        assert_raise ArgumentError, ~r/invalid ONIX dataset host/, fn ->
          Export.record_reference("p1")
        end
      end
    end
  end
end
