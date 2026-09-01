defmodule Barkpark.Sites.DeployRequestTest do
  @moduledoc """
  The prebuilt pair on the request struct (site-spawner charter D86/D87).

  The regression these tests exist for is a SILENT one: before this change
  `new/1` read only the keys it knew, so a control plane that shipped
  `artifact_b64` to an un-upgraded box got `{:ok, req}` with no artifact, the
  box rebuilt from the template, HEALTH passed on genuine markers, and the site
  went live with the wrong bytes. Every assertion below is that the handshake
  now REFUSES rather than shrugs.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sites.DeployRequest

  defp params(extra \\ %{}) do
    Map.merge(%{"slug" => "my-site", "build_id" => "b1", "mode" => "deploy"}, extra)
  end

  defp artifact_pair(body \\ "hello") do
    raw = :zlib.gzip(body)
    {Base.encode64(raw), :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)}
  end

  describe "the prebuilt pair" do
    test "both keys survive new/1 as first-class struct fields" do
      {b64, sha} = artifact_pair()

      assert {:ok, req} =
               DeployRequest.new(params(%{"artifact_b64" => b64, "artifact_sha256" => sha}))

      assert req.artifact_b64 == b64
      assert req.artifact_sha256 == sha
      assert DeployRequest.prebuilt?(req)
    end

    test "a request WITHOUT them is unchanged, and is not prebuilt" do
      assert {:ok, req} = DeployRequest.new(params())
      assert req.artifact_b64 == nil
      assert req.artifact_sha256 == nil
      refute DeployRequest.prebuilt?(req)
    end

    test "THE SILENT DROP IS CLOSED: artifact_b64 can no longer vanish into an {:ok, req}" do
      {b64, _sha} = artifact_pair()

      # The pre-change behavior was {:ok, %DeployRequest{}} with the artifact
      # simply absent. Now it is a typed 400 — half a handshake is refused.
      assert {:error, "invalid_artifact_digest", message} =
               DeployRequest.new(params(%{"artifact_b64" => b64}))

      assert message =~ "artifact_sha256 is required"

      # And a genuinely unknown key still behaves as it always did (dropped) —
      # this test pins the ARTIFACT keys, and nothing wider.
      assert {:ok, req} = DeployRequest.new(params(%{"totally_unknown_key" => "x"}))
      assert req.slug == "my-site"
    end

    test "a digest with no artifact is refused (a digest alone deploys nothing)" do
      {_b64, sha} = artifact_pair()

      assert {:error, "invalid_artifact", message} =
               DeployRequest.new(params(%{"artifact_sha256" => sha}))

      assert message =~ "artifact_b64 is required"
    end

    test "a malformed digest is refused" do
      {b64, _sha} = artifact_pair()

      for bad <- [
            "not-a-digest",
            String.duplicate("A", 64),
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            String.duplicate("a", 64) <> "\n"
          ] do
        result = DeployRequest.new(params(%{"artifact_b64" => b64, "artifact_sha256" => bad}))

        assert match?({:error, "invalid_artifact_digest", _}, result),
               "expected #{inspect(bad)} to be refused as a digest, got #{inspect(result)}"
      end
    end

    test "a non-base64 body is refused" do
      {_b64, sha} = artifact_pair()

      assert {:error, "invalid_artifact", message} =
               DeployRequest.new(
                 params(%{"artifact_b64" => "!!! not base64 !!!", "artifact_sha256" => sha})
               )

      assert message =~ "base64"
    end

    test "an empty body carrying a digest is refused, never treated as absent" do
      {_b64, sha} = artifact_pair()

      assert {:error, "invalid_artifact", message} =
               DeployRequest.new(params(%{"artifact_b64" => "", "artifact_sha256" => sha}))

      assert message =~ "base64"
    end

    test "BOTH keys empty is the honest absent case, not an error" do
      assert {:ok, req} =
               DeployRequest.new(params(%{"artifact_b64" => "", "artifact_sha256" => ""}))

      refute DeployRequest.prebuilt?(req)
    end

    test "an over-cap artifact is refused by SIZE before it is ever decoded" do
      {_b64, sha} = artifact_pair()
      oversized = String.duplicate("A", DeployRequest.max_artifact_bytes() * 2)

      assert {:error, "artifact_too_large", message} =
               DeployRequest.new(params(%{"artifact_b64" => oversized, "artifact_sha256" => sha}))

      assert message =~ "#{DeployRequest.max_artifact_bytes()}"
    end

    test "a decoded artifact over the cap is refused" do
      raw = :binary.copy("x", DeployRequest.max_artifact_bytes() + 1)
      b64 = Base.encode64(raw)
      sha = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)

      assert {:error, "artifact_too_large", message} =
               DeployRequest.new(params(%{"artifact_b64" => b64, "artifact_sha256" => sha}))

      assert message =~ "decoded"
    end

    test "the pair is refused on a rollback and on a teardown" do
      {b64, sha} = artifact_pair()

      for mode <- ~w(rollback teardown) do
        assert {:error, "invalid_artifact", message} =
                 DeployRequest.new(
                   params(%{
                     "mode" => mode,
                     "artifact_b64" => b64,
                     "artifact_sha256" => sha
                   })
                 )

        assert message =~ "mode=deploy", "mode #{mode} must refuse an artifact"
      end
    end

    test "a wrapped (newline-bearing) base64 body is accepted — encoders wrap" do
      {b64, sha} = artifact_pair()

      wrapped =
        b64
        |> String.to_charlist()
        |> Enum.chunk_every(60)
        |> Enum.map_join("\n", &List.to_string/1)

      assert {:ok, req} =
               DeployRequest.new(params(%{"artifact_b64" => wrapped, "artifact_sha256" => sha}))

      assert req.artifact_sha256 == sha
    end

    test "artifact values that are not strings are refused" do
      assert {:error, "invalid_artifact", _} =
               DeployRequest.new(params(%{"artifact_b64" => 42, "artifact_sha256" => 7}))
    end
  end
end
