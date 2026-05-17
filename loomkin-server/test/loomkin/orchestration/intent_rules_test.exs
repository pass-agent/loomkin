defmodule Loomkin.Orchestration.IntentRulesTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.IntentRules

  describe "fast_chat" do
    test "empty/whitespace → fast_chat" do
      assert {:fast_chat, _} = IntentRules.classify("")
      assert {:fast_chat, _} = IntentRules.classify("   \n  ")
      assert {:fast_chat, _} = IntentRules.classify(nil)
    end

    test "very short → fast_chat" do
      for msg <- ~w(hi ok no yes) do
        assert {:fast_chat, _} = IntentRules.classify(msg)
      end
    end

    test "greetings and acknowledgements → fast_chat" do
      for msg <- [
            "hello",
            "thanks",
            "thank you",
            "sounds good",
            "got it",
            "Hey there",
            "Cool!",
            "Sure, go ahead"
          ] do
        assert {:fast_chat, _} = IntentRules.classify(msg),
               "expected fast_chat for: #{inspect(msg)}"
      end
    end

    test "short question with no code or file path → fast_chat" do
      assert {:fast_chat, _} = IntentRules.classify("what does Loomkin do?")
      assert {:fast_chat, _} = IntentRules.classify("how should I think about teams?")
    end
  end

  describe "complex_task" do
    test "message containing a diff in a code fence → complex_task" do
      diff = """
      ```
      diff --git a/x.ex b/x.ex
      @@ -1 +1 @@
      - old
      + new
      ```
      """

      assert {:complex_task, _} = IntentRules.classify(diff)
    end

    test "action verb + file path → complex_task" do
      assert {:complex_task, _} =
               IntentRules.classify("refactor lib/loomkin/session/session.ex to use gen_statem")

      assert {:complex_task, _} =
               IntentRules.classify("fix the bug in apps/cli/src/index.tsx")
    end

    test "multi-paragraph message with spec keywords → complex_task" do
      msg = """
      ## Goal
      Add a new feature.

      ## Acceptance criteria
      - Function returns :ok
      - Covered by a test
      """

      assert {:complex_task, _} = IntentRules.classify(msg)
    end
  end

  describe "tool_use" do
    test "action verb without file scope and short → tool_use" do
      assert {:tool_use, _} = IntentRules.classify("run the tests")
      assert {:tool_use, _} = IntentRules.classify("format the code")
      assert {:tool_use, _} = IntentRules.classify("audit the recent commits")
    end
  end

  describe "ambiguous" do
    test "anything that fits no rule → ambiguous" do
      assert {:ambiguous, _} =
               IntentRules.classify(
                 "I'm thinking about the architecture and want to talk through tradeoffs"
               )
    end
  end

  describe "which_rule/1" do
    test "returns 1 for empty, 3 for greeting, 6 for action+path, 0 for ambiguous" do
      assert IntentRules.which_rule("") == 1
      assert IntentRules.which_rule("hi") == 2
      assert IntentRules.which_rule("hello") == 3
      assert IntentRules.which_rule("refactor lib/x.ex now") == 6
      assert IntentRules.which_rule("I'm thinking about architecture tradeoffs") == 0
    end
  end
end
