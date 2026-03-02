defmodule Loomkin.ToolTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tool

  describe "safe_path!/2" do
    @tag :tmp_dir
    test "allows paths within project", %{tmp_dir: proj} do
      assert Tool.safe_path!("foo.ex", proj) == Path.join(proj, "foo.ex")
    end

    @tag :tmp_dir
    test "allows nested paths within project", %{tmp_dir: proj} do
      assert Tool.safe_path!("lib/app/server.ex", proj) == Path.join(proj, "lib/app/server.ex")
    end

    @tag :tmp_dir
    test "allows project root itself", %{tmp_dir: proj} do
      assert Tool.safe_path!(".", proj) == Path.expand(proj)
    end

    @tag :tmp_dir
    test "blocks ../etc/passwd traversal", %{tmp_dir: proj} do
      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!("../../etc/passwd", proj)
      end
    end

    @tag :tmp_dir
    test "blocks absolute path outside project", %{tmp_dir: proj} do
      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!("/etc/passwd", proj)
      end
    end

    @tag :tmp_dir
    test "blocks path with embedded .. segments", %{tmp_dir: proj} do
      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!("lib/../../../../../../etc/passwd", proj)
      end
    end

    @tag :tmp_dir
    test "blocks symlink pointing outside project", %{tmp_dir: proj} do
      link_path = Path.join(proj, "escape_link")
      File.ln_s!("/etc", link_path)

      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!("escape_link/passwd", proj)
      end
    end

    @tag :tmp_dir
    test "blocks nested symlink escaping project", %{tmp_dir: proj} do
      subdir = Path.join(proj, "subdir")
      File.mkdir_p!(subdir)
      link_path = Path.join(subdir, "sneaky")
      File.ln_s!("/tmp", link_path)

      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!("subdir/sneaky/something", proj)
      end
    end

    @tag :tmp_dir
    test "allows symlink within project", %{tmp_dir: proj} do
      real_dir = Path.join(proj, "real_dir")
      File.mkdir_p!(real_dir)
      File.write!(Path.join(real_dir, "file.txt"), "content")
      link_path = Path.join(proj, "link_dir")
      File.ln_s!(real_dir, link_path)

      result = Tool.safe_path!("link_dir/file.txt", proj)
      # Should resolve to the real path within the project
      assert String.starts_with?(result, Path.expand(proj))
    end

    @tag :tmp_dir
    test "handles . segments correctly", %{tmp_dir: proj} do
      assert Tool.safe_path!("./lib/./app.ex", proj) == Path.join(proj, "lib/app.ex")
    end

    @tag :tmp_dir
    test "raises on symlink loop instead of hanging", %{tmp_dir: proj} do
      # Create a symlink loop: loop_a -> loop_b -> loop_a
      File.ln_s!(Path.join(proj, "loop_b"), Path.join(proj, "loop_a"))
      File.ln_s!(Path.join(proj, "loop_a"), Path.join(proj, "loop_b"))

      assert_raise ArgumentError, ~r/Too many levels of symlinks/, fn ->
        Tool.safe_path!("loop_a/file.txt", proj)
      end
    end

    @tag :tmp_dir
    test "handles unicode filenames", %{tmp_dir: proj} do
      result = Tool.safe_path!("lib/modulo_espanol.ex", proj)
      assert result == Path.join(proj, "lib/modulo_espanol.ex")

      result2 = Tool.safe_path!("lib/日本語.ex", proj)
      assert result2 == Path.join(proj, "lib/日本語.ex")
    end

    @tag :tmp_dir
    test "prevents prefix confusion with similar project names", %{tmp_dir: proj} do
      # Ensure "/tmp/proj" doesn't match "/tmp/project2"
      fake_path = proj <> "2/malicious.txt"

      assert_raise ArgumentError, ~r/outside the project/, fn ->
        Tool.safe_path!(fake_path, proj)
      end
    end
  end

  describe "param!/2" do
    test "gets atom key" do
      assert Tool.param!(%{name: "hello"}, :name) == "hello"
    end

    test "falls back to string key" do
      assert Tool.param!(%{"name" => "hello"}, :name) == "hello"
    end

    test "raises on missing key" do
      assert_raise KeyError, fn ->
        Tool.param!(%{}, :name)
      end
    end
  end

  describe "param/3" do
    test "gets atom key" do
      assert Tool.param(%{name: "hello"}, :name) == "hello"
    end

    test "falls back to string key" do
      assert Tool.param(%{"name" => "hello"}, :name) == "hello"
    end

    test "returns default when missing" do
      assert Tool.param(%{}, :name, "default") == "default"
    end

    test "returns nil default" do
      assert Tool.param(%{}, :name) == nil
    end
  end
end
