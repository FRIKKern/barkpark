defmodule Barkpark.PortableDoc.Render.FormsTest do
  # Pure HTML emitter — no DB, no side-effects.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Forms

  describe "form_html/2 — section wrapper and kind class" do
    test "defaults to bp-form-grill when kind is absent" do
      html = Forms.form_html(%{}, :article)
      assert html =~ ~s(class="bp-form bp-form-grill")
    end

    test "uses bp-form-questionnaire class when kind is questionnaire" do
      html = Forms.form_html(%{"kind" => "questionnaire"}, :email)
      assert html =~ ~s(class="bp-form bp-form-questionnaire")
    end

    test "renders empty section with no questions" do
      html = Forms.form_html(%{"questions" => []}, :article)
      assert html == ~s(<section class="bp-form bp-form-grill"></section>)
    end
  end

  describe "form_html/2 — question rendering" do
    test "renders a text question with prompt, rationale, and textarea" do
      block = %{
        "questions" => [
          %{
            "id" => "q1",
            "prompt" => "What is your goal?",
            "type" => "text",
            "rationale" => "Helps focus the work."
          }
        ]
      }

      html = Forms.form_html(block, :article)
      assert html =~ "<fieldset"
      assert html =~ "<legend>What is your goal?</legend>"
      assert html =~ "Helps focus the work."
      assert html =~ ~s(<textarea name="q1" rows="3">)
    end

    test "renders yesno question with Yes and No radio buttons" do
      block = %{
        "questions" => [
          %{"id" => "yn", "prompt" => "Is this correct?", "type" => "yesno"}
        ]
      }

      html = Forms.form_html(block, :email)
      assert html =~ ~s(type="radio" name="yn" value="Yes")
      assert html =~ ~s(type="radio" name="yn" value="No")
    end

    test "renders single-choice question as radio group with given options" do
      block = %{
        "questions" => [
          %{
            "id" => "q2",
            "prompt" => "Pick one",
            "type" => "single",
            "options" => ["Alpha", "Beta", "Gamma"]
          }
        ]
      }

      html = Forms.form_html(block, :article)
      assert html =~ ~s(type="radio" name="q2" value="Alpha")
      assert html =~ ~s(type="radio" name="q2" value="Beta")
      assert html =~ ~s(type="radio" name="q2" value="Gamma")
    end

    test "renders multi-choice question as checkboxes" do
      block = %{
        "questions" => [
          %{
            "id" => "q3",
            "prompt" => "Pick all that apply",
            "type" => "multi",
            "options" => ["X", "Y"]
          }
        ]
      }

      html = Forms.form_html(block, :email)
      assert html =~ ~s(type="checkbox" name="q3" value="X")
      assert html =~ ~s(type="checkbox" name="q3" value="Y")
    end

    test "renders scale question with numeric radio buttons from min to max" do
      block = %{
        "questions" => [
          %{
            "id" => "q4",
            "prompt" => "Rate it",
            "type" => "scale",
            "scale" => %{"min" => 1, "max" => 3}
          }
        ]
      }

      html = Forms.form_html(block, :article)
      assert html =~ ~s(type="radio" name="q4" value="1")
      assert html =~ ~s(type="radio" name="q4" value="2")
      assert html =~ ~s(type="radio" name="q4" value="3")
      refute html =~ ~s(value="4")
    end

    test "malformed authored form values render safely in article and email modes" do
      for style <- [:article, :email],
          scale <- [nil, "legacy", [], 42, %{"min" => "bad", "max" => %{}}] do
        block = %{
          "kind" => %{"legacy" => true},
          "questions" => [
            %{
              "id" => %{"legacy" => true},
              "prompt" => %{"legacy" => true},
              "type" => "scale",
              "rationale" => ["legacy"],
              "recommendation" => %{"legacy" => true},
              "options" => %{"legacy" => true},
              "scale" => scale
            },
            %{
              "id" => "choice",
              "prompt" => "Choice",
              "type" => "single",
              "options" => %{"legacy" => true}
            }
          ]
        }

        html = Forms.form_html(block, style)
        assert html =~ ~s(class="bp-form bp-form-grill")
        assert html =~ ~s(type="radio" name="" value="1")
        assert html =~ ~s(type="radio" name="" value="5")
        assert html =~ ~s(type="radio" name="choice" value="")
      end
    end

    test "caps scale ladder span so a huge author-supplied max cannot exhaust memory" do
      # Guards the public /papers/:slug render: without a cap, scale.max in the
      # millions materializes a giant range + that many radio inputs on every
      # unauthenticated render (mirrors the Go TUI maxLadder=100 hardening).
      block = %{
        "questions" => [
          %{
            "id" => "big",
            "prompt" => "Rate it",
            "type" => "scale",
            "scale" => %{"min" => 1, "max" => 1_000_000}
          }
        ]
      }

      html = Forms.form_html(block, :article)

      radio_count =
        html |> String.split(~s(type="radio")) |> length() |> Kernel.-(1)

      assert radio_count <= 101
      # The span is clamped at min + 100, so 101 is the last rung and 102 is out.
      assert html =~ ~s(value="101")
      refute html =~ ~s(value="102")
    end

    test "unknown type degrades to textarea (never crashes)" do
      block = %{
        "questions" => [
          %{"id" => "q5", "prompt" => "Some prompt", "type" => "widget_unknown"}
        ]
      }

      html = Forms.form_html(block, :email)
      assert html =~ ~s(<textarea name="q5" rows="3">)
    end

    test "escapes HTML special characters in prompt and rationale" do
      block = %{
        "questions" => [
          %{
            "id" => "safe",
            "prompt" => "<script>alert('xss')</script>",
            "type" => "text",
            "rationale" => "a & b > c"
          }
        ]
      }

      html = Forms.form_html(block, :article)
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "a &amp; b &gt; c"
    end
  end
end
