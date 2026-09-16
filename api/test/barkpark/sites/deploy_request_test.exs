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

  # ── source_kind: WHO OWNS <slug>/src ──────────────────────────────────────
  #
  # This axis decides whether `Barkpark.Sites.Provisioner` may DELETE the site's
  # source tree. Both directions matter and are asserted here: a value read as
  # content-bound when it is not clobbers the customer's code; a value read as
  # external when it is not leaves the box with no source and BUILD dies.

  describe "source_kind" do
    test "defaults to :content_bound when absent, empty, or from a pre-guard caller" do
      assert {:ok, req} = DeployRequest.new(%{"slug" => "s", "build_id" => "b"})
      assert req.source_kind == :content_bound
      assert DeployRequest.content_bound?(req)
      refute DeployRequest.external_source?(req)

      assert {:ok, blank} =
               DeployRequest.new(%{"slug" => "s", "build_id" => "b", "source_kind" => ""})

      assert blank.source_kind == :content_bound
    end

    test "every accepted wire value maps to its atom, and ownership is decided BOTH ways" do
      expected = %{
        "content-bound" => {:content_bound, true},
        "external-git" => {:external_git, false},
        "external-artifact" => {:external_artifact, false}
      }

      # The table covers the enum EXACTLY — a kind added to DeployRequest with
      # no ownership decision here reds this line.
      assert Enum.sort(Map.keys(expected)) == DeployRequest.source_kinds()

      for {wire, {atom, content_bound?}} <- expected do
        assert {:ok, req} =
                 DeployRequest.new(%{"slug" => "s", "build_id" => "b", "source_kind" => wire})

        assert req.source_kind == atom, "#{wire} must parse to #{inspect(atom)}"

        assert DeployRequest.content_bound?(req) == content_bound?,
               "#{wire}: content_bound? must be #{content_bound?}"

        # The two predicates are exact complements — no third state can open a
        # gap that reads as "safe to delete".
        assert DeployRequest.external_source?(req) == not content_bound?
      end
    end

    test "an unknown source_kind is a 400, NEVER a silent drop to content-bound" do
      for bogus <- ["external", "git", "Content-Bound", "content_bound", "../x", "  "] do
        result = DeployRequest.new(%{"slug" => "s", "build_id" => "b", "source_kind" => bogus})

        # Bound first so the message is REACHABLE (assert/2 drops a message
        # given to the `assert pattern = expr` macro form).
        assert match?({:error, "invalid_source_kind", _}, result),
               "#{inspect(bogus)} was ACCEPTED (#{inspect(result)}) — an un-upgraded " <>
                 "box would silently default it to content-bound and clobber the source"

        {:error, _code, msg} = result
        assert msg =~ "external-git"
      end
    end

    test "a non-string source_kind is a 400" do
      for bogus <- [123, %{}, ["external-git"], true] do
        assert {:error, "invalid_source_kind", _} =
                 DeployRequest.new(%{"slug" => "s", "build_id" => "b", "source_kind" => bogus})
      end
    end

    test "a hand-built struct carrying an UNDECLARED kind is externally owned (fail-closed)" do
      # new/1 cannot produce this — the enum is closed. A future migration or a
      # hand-rolled struct can. The safe default for "who owns this tree?" is
      # NOT the answer that deletes it.
      req = %DeployRequest{slug: "s", mode: :deploy, source_kind: :external_svn}
      refute DeployRequest.content_bound?(req)
      assert DeployRequest.external_source?(req)
    end

    test "source_kind is INDEPENDENT of the prebuilt artifact pair" do
      artifact = Base.encode64("prebuilt-dist-bytes")
      sha = :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower)

      assert {:ok, req} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b",
                 "artifact_b64" => artifact,
                 "artifact_sha256" => sha
               })

      # A prebuilt deploy stages a dist/, not a src/ — it stays content-bound,
      # which is exactly the behaviour that lane has today.
      assert DeployRequest.prebuilt?(req)
      assert req.source_kind == :content_bound
      assert DeployRequest.content_bound?(req)
    end
  end
end
