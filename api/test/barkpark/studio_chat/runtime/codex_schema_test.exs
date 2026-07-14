defmodule Barkpark.StudioChat.Runtime.CodexSchemaTest do
  use ExUnit.Case, async: true

  @schema_root Path.expand(
                 "../../../../priv/codex_app_server_schema/0.144.1/schema",
                 __DIR__
               )
  @manifest_path Path.join(Path.dirname(@schema_root), "manifest.json")

  test "pins the complete stable 0.144.1 schema with a path-independent digest" do
    manifest = decode!(@manifest_path)
    schema_files = schema_files()

    assert manifest["package"] == "@openai/codex"
    assert manifest["version"] == "0.144.1"
    assert manifest["schema_profile"] == "stable"
    assert manifest["transport"] == "stdio-jsonl"
    assert manifest["experimental"] == false
    assert manifest["paid_turn_required"] == false
    assert manifest["schema_file_count"] == 267
    assert length(schema_files) == manifest["schema_file_count"]
    assert canonical_digest(schema_files) == manifest["canonical_sha256"]
  end

  test "pins the handshake, lifecycle, approval, and readiness method vocabulary" do
    assert_methods("ClientRequest.json", [
      "initialize",
      "thread/start",
      "thread/resume",
      "turn/start",
      "turn/interrupt",
      "account/read"
    ])

    assert_methods("ClientNotification.json", ["initialized"])

    assert_methods("ServerRequest.json", [
      "item/commandExecution/requestApproval",
      "item/fileChange/requestApproval",
      "item/permissions/requestApproval"
    ])

    assert_methods("ServerNotification.json", [
      "error",
      "thread/started",
      "turn/started",
      "turn/completed",
      "item/agentMessage/delta",
      "item/commandExecution/outputDelta",
      "item/started",
      "item/completed"
    ])
  end

  test "pins required native identifiers and truthful read-only auth fields" do
    assert required("v2/ThreadResumeParams.json") == ["threadId"]
    assert required("v2/TurnStartParams.json") == ["input", "threadId"]
    assert required("v2/TurnInterruptParams.json") == ["threadId", "turnId"]
    assert required("v2/GetAccountResponse.json") == ["requiresOpenaiAuth"]

    account = decode_schema!("v2/GetAccountResponse.json")["definitions"]["Account"]

    assert one_of_enum_values(account) == ["amazonBedrock", "apiKey", "chatgpt"]
  end

  test "pins allow, session-allow, deny, and cancel approval decisions" do
    for {file, definition} <- [
          {"CommandExecutionRequestApprovalResponse.json", "CommandExecutionApprovalDecision"},
          {"FileChangeRequestApprovalResponse.json", "FileChangeApprovalDecision"}
        ] do
      schema = decode_schema!(file)
      decision = schema["definitions"][definition]

      assert Enum.sort(one_of_enum_values(decision)) ==
               Enum.sort(["accept", "acceptForSession", "decline", "cancel"])
    end
  end

  defp assert_methods(file, expected) do
    methods = decode_schema!(file) |> method_values()

    assert MapSet.subset?(MapSet.new(expected), MapSet.new(methods)),
           "#{file} is missing one of #{inspect(expected)}; got #{inspect(methods)}"
  end

  defp method_values(%{"oneOf" => variants}) do
    Enum.flat_map(variants, fn variant ->
      get_in(variant, ["properties", "method", "enum"]) || []
    end)
  end

  defp required(file), do: decode_schema!(file)["required"] || []

  defp one_of_enum_values(%{"oneOf" => variants}) do
    variants
    |> Enum.flat_map(fn variant ->
      Map.get(variant, "enum") || get_in(variant, ["properties", "type", "enum"]) || []
    end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp schema_files do
    @schema_root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.sort_by(&Path.relative_to(&1, @schema_root))
  end

  defp canonical_digest(files) do
    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, hash ->
      relative_path = Path.relative_to(path, @schema_root)
      canonical_document = path |> decode!() |> canonical_json() |> IO.iodata_to_binary()

      :crypto.hash_update(
        hash,
        <<byte_size(relative_path)::unsigned-big-32, relative_path::binary,
          byte_size(canonical_document)::unsigned-big-64, canonical_document::binary>>
      )
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ?:, canonical_json(nested)] end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  defp canonical_json(value) when is_list(value) do
    [?[, value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp decode_schema!(relative_path), do: decode!(Path.join(@schema_root, relative_path))
  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
