defmodule Barkpark.PortableDoc.Render.StatusVocabTest do
  # Locks the design/status-manifest.json contract: these are the EXACT values
  # every surface derives from. A bad manifest edit fails here; the CSS/Go/web
  # drift is caught by scripts/status-manifest-check.sh.
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.StatusVocab

  test "status → role: stored lifecycle values, aliases, and the open default" do
    assert StatusVocab.role_for_status("open") == "open"
    assert StatusVocab.role_for_status("ready") == "ready"
    assert StatusVocab.role_for_status("in_progress") == "progress"
    assert StatusVocab.role_for_status("blocked") == "blocked"
    assert StatusVocab.role_for_status("done") == "done"
    assert StatusVocab.role_for_status("closed") == "done"
    assert StatusVocab.role_for_status("cancelled") == "cancel"
    assert StatusVocab.role_for_status("whatever") == "open"
    assert StatusVocab.role_for_status(nil) == "open"
  end

  test "role → glyph is the exact white ladder" do
    assert StatusVocab.glyph_for_role("open") == "○"
    assert StatusVocab.glyph_for_role("ready") == "○"
    assert StatusVocab.glyph_for_role("blocked") == "!"
    assert StatusVocab.glyph_for_role("done") == "✓"
    assert StatusVocab.glyph_for_role("cancel") == "✕"
    # progress carries no static glyph — the CSS ::before animates the spinner
    assert StatusVocab.glyph_for_role("progress") == ""
  end

  test "only progress is a spinner role" do
    assert StatusVocab.spinner?("progress")
    refute StatusVocab.spinner?("done")
    refute StatusVocab.spinner?("open")
    refute StatusVocab.spinner?("unknown")
  end

  test "roles order + tone tokens are exposed from the manifest" do
    assert StatusVocab.roles() == ~w(open ready progress blocked done cancel)
    assert StatusVocab.tones()["ok"] == %{"light" => "#0d9488", "dark" => "#2dd4bf"}
    assert StatusVocab.tones()["danger"]["dark"] == "#f87171"
  end
end
