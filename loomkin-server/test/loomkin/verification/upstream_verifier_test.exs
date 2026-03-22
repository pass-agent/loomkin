defmodule Loomkin.Verification.UpstreamVerifierTest do
  use ExUnit.Case, async: true

  alias Loomkin.Verification.UpstreamVerifier

  describe "module existence" do
    test "module is loaded" do
      assert Code.ensure_loaded?(UpstreamVerifier)
    end

    test "exports start/1" do
      Code.ensure_loaded!(UpstreamVerifier)
      assert function_exported?(UpstreamVerifier, :start, 1)
    end

    test "exports tools/0" do
      Code.ensure_loaded!(UpstreamVerifier)
      assert function_exported?(UpstreamVerifier, :tools, 0)
    end
  end

  describe "tools/0" do
    test "returns 5 tool modules" do
      tools = UpstreamVerifier.tools()
      assert length(tools) == 5
    end

    test "includes AcceptanceChecks" do
      assert Loomkin.Tools.AcceptanceChecks in UpstreamVerifier.tools()
    end

    test "includes FileRead for code inspection" do
      assert Loomkin.Tools.FileRead in UpstreamVerifier.tools()
    end

    test "includes ContentSearch for searching" do
      assert Loomkin.Tools.ContentSearch in UpstreamVerifier.tools()
    end

    test "includes Shell for running commands" do
      assert Loomkin.Tools.Shell in UpstreamVerifier.tools()
    end

    test "includes LspDiagnostics" do
      assert Loomkin.Tools.LspDiagnostics in UpstreamVerifier.tools()
    end

    test "does not include write tools" do
      tools = UpstreamVerifier.tools()
      refute Loomkin.Tools.FileEdit in tools
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.Git in tools
    end
  end
end
