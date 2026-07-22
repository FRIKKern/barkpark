defmodule Barkpark.Content.Papers.NoteCardFieldLossTest do
  @moduledoc """
  The silent-content-loss write gate (pd-note-block-silent-content-loss).

  A `note` or `card` block whose prose is authored under a key the renderer
  never reads (`content` on a note, top-level `title`/`body` on a slots-native
  card) renders an EMPTY shell behind an HTTP 200 — the label/skeleton survives,
  the prose is gone, and BOTH validation layers return no error. This suite
  proves the NARROW write-side RATCHET that closes it:

    * `Slots.lossy_shape?/1` — the predicate: renders no prose AND an unknown key
      holds semantic text. Populated-consumed blocks (however many extra keys)
      and undeclared types are never flagged.
    * `upsert_paper` — a NEW lossy note/card is refused with the plugin-veto
      halt shape; a clean paper cannot be re-upserted into the lossy shape; an
      ALREADY-lossy row re-saves untouched (no brick). Fires with NO locked block
      present — the unconditional seam Template.validate skips for 416/419 papers.
    * `apply_paper_block_op` — the canvas edge: a clean block edited down into the
      lossy shape halts, an already-lossy paper stays editable.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.PortableDoc.Slots
  alias Barkpark.Content.Papers.Template
  alias Barkpark.Repo

  @dataset "production"

  # ── fixtures ────────────────────────────────────────────────────────────

  defp locked_title(text) do
    %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => text
    }
  end

  defp para(text, id \\ "p1") do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  # A note in the LOSSY shape: no consumed field, prose stranded under `content`.
  defp lossy_note(id \\ "n1"),
    do: %{"id" => id, "type" => "note", "content" => "Stranded note prose"}

  # A clean note (label + body populated).
  defp clean_note(id \\ "n1"),
    do: %{"id" => id, "type" => "note", "label" => "Fix", "text" => "A real note body"}

  # A card in the LOSSY shape: slots-native type authored FLAT (title/body top
  # level, no `slots` wrapper) — every consumed slot empty, prose stranded.
  defp lossy_card(id \\ "c1"),
    do: %{"id" => id, "type" => "card", "title" => "Card title", "body" => "Card body prose"}

  defp fresh_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── Slots.lossy_shape?/1 — the predicate ────────────────────────────────

  describe "Slots.lossy_shape?/1" do
    test "a note with prose under `content` (no consumed field) is lossy" do
      assert Slots.lossy_shape?(lossy_note())
    end

    test "a flat-authored card (title/body top level, no slots) is lossy" do
      assert Slots.lossy_shape?(lossy_card())
    end

    test "NO FALSE ALARM: a note with a real body plus an experimental key is NOT lossy" do
      refute Slots.lossy_shape?(Map.put(clean_note(), "experimental", "chrome text"))
    end

    test "NO FALSE ALARM: a slots-native card with real slots + tone is NOT lossy" do
      card = %{
        "id" => "c2",
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "title" => [%{"type" => "heading", "text" => "T"}],
          "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}]
        }
      }

      refute Slots.lossy_shape?(card)
    end

    test "a genuinely empty note (no unknown loud key) is NOT lossy — empty, not LOSS" do
      refute Slots.lossy_shape?(%{"id" => "n0", "type" => "note"})
    end

    test "a stray boolean under an unknown key is not 'loud' (needs semantic text)" do
      refute Slots.lossy_shape?(%{"id" => "n0", "type" => "note", "collapsed" => false})
    end

    test "an undeclared block type is never flagged (the wider census is separate)" do
      refute Slots.lossy_shape?(%{"id" => "x", "type" => "paragraph", "mystery" => "hi"})
      # `quote` carries no field_vocab — an undeclared type stays untouched.
      # (`callout` USED to sit here; the census gate now declares it — see
      # BlockFieldCensusTest for its positive coverage.)
      refute Slots.lossy_shape?(%{"id" => "x", "type" => "quote", "mystery" => "hi"})
    end
  end

  # ── upsert_paper — NEW lossy write is refused ───────────────────────────

  describe "upsert_paper field-loss gate" do
    test "a NEW lossy note is rejected with the halt shape, and nothing persists" do
      slug = fresh_slug("loss-note")

      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Notes",
                   blocks: [locked_title("Notes"), para("Real body."), lossy_note()]
                 })
               )

      assert msg =~ "renderer ignores"
      assert Content.get_paper(slug, @dataset) == nil
    end

    test "a NEW flat-authored card is rejected too (card has no legacy_slot clause)" do
      slug = fresh_slug("loss-card")

      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Cards",
                   blocks: [locked_title("Cards"), lossy_card()]
                 })
               )

      assert msg =~ "renderer ignores"
      assert Content.get_paper(slug, @dataset) == nil
    end

    test "SEAM UNCONDITIONAL: the rejection fires on a paper with NO locked block" do
      slug = fresh_slug("loss-unlocked")

      blocks = [para("Real body, no locked title."), lossy_note()]
      # Precondition: the block list Template.validate/Constraints skip entirely.
      refute Enum.any?(blocks, &Template.locked?/1)

      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Unlocked",
                   blocks: blocks
                 })
               )

      assert msg =~ "renderer ignores"
    end

    test "NO FALSE ALARM: a real note (populated body) beside a body block saves" do
      slug = fresh_slug("ok-note")

      assert {:ok, doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "OK",
                   blocks: [locked_title("OK"), para("Body."), clean_note()]
                 })
               )

      assert doc.status == "published"
    end
  end

  # ── the RATCHET — existing losses do not brick, clean cannot go lossy ────

  # A stored paper carrying an ALREADY-lossy note (the live-corpus shape): seed a
  # real paper through the front door, then write the lossy note into the ROW
  # directly (bypassing the gate), exactly as the five live losses exist today.
  defp seed_stored_lossy_note! do
    slug = fresh_slug("ratchet-loss")

    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          title: "Ratchet",
          blocks: [locked_title("Ratchet"), para("Body block.", "p1")]
        })
      )

    blocks = [locked_title("Ratchet"), para("Body block.", "p1"), lossy_note("n1")]

    {:ok, _} =
      doc
      |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", blocks)})
      |> Repo.update()

    slug
  end

  describe "upsert_paper ratchet" do
    test "RATCHET: an already-lossy row re-saves (does not brick)" do
      slug = seed_stored_lossy_note!()
      doc = Content.get_paper(slug, @dataset)
      # Sanity: the stored note IS lossy today.
      assert doc.content["blocks"] |> Enum.any?(&Slots.lossy_shape?/1)

      # Re-submit the SAME blocks — an author re-saving the affected paper.
      assert {:ok, saved} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Ratchet",
                   blocks: doc.content["blocks"]
                 })
               )

      assert saved.status == "published"
    end

    test "RATCHET: a clean paper cannot be re-upserted into the lossy shape" do
      slug = fresh_slug("ratchet-clean")

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            title: "Clean",
            blocks: [locked_title("Clean"), para("Body."), clean_note("n1")]
          })
        )

      # Same slug, same note id — but now authored lossy. Clean → lossy: refused.
      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Clean",
                   blocks: [locked_title("Clean"), para("Body."), lossy_note("n1")]
                 })
               )

      assert msg =~ "renderer ignores"
    end
  end

  describe "apply_paper_block_op ratchet (canvas edge)" do
    test "editing a clean note DOWN into the lossy shape halts, paper unchanged" do
      slug = fresh_slug("op-clean")

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            title: "Op",
            blocks: [locked_title("Op"), para("Body."), clean_note("n1")]
          })
        )

      # Blank the consumed fields and strand the prose under `content`.
      op = %{
        "op" => "patch-block",
        "id" => "n1",
        "patch" => %{"label" => "", "text" => "", "content" => "Stranded on canvas"}
      }

      assert {:error, {:halted, msg}} = Content.apply_paper_block_op(slug, op, @dataset)
      assert msg =~ "renderer ignores"

      # Nothing persisted — the note still reads through clean.
      doc = Content.get_paper(slug, @dataset)
      note = Enum.find(doc.content["blocks"], &(&1["id"] == "n1"))
      refute Slots.lossy_shape?(note)
    end

    test "an already-lossy paper stays editable (a benign op lands)" do
      slug = seed_stored_lossy_note!()

      op = %{"op" => "append-block", "block" => para("Another real block.", "p2")}
      assert {:ok, _} = Content.apply_paper_block_op(slug, op, @dataset)

      doc = Content.get_paper(slug, @dataset)
      assert Enum.any?(doc.content["blocks"], &(&1["id"] == "p2"))
    end
  end
end
