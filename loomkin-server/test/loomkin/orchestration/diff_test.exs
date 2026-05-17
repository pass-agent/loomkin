defmodule Loomkin.Orchestration.DiffTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Diff

  setup do
    path = Path.join(System.tmp_dir!(), "orch-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Diff Test"], cd: path)

    File.write!(Path.join(path, "README.md"), "initial\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)

    on_exit(fn -> File.rm_rf(path) end)
    %{path: path}
  end

  defp commit_change(path, files, message) do
    Enum.each(files, fn {name, contents} ->
      File.write!(Path.join(path, name), contents)
    end)

    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", message], cd: path)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    String.trim(sha)
  end

  test "captures stats, per-file numstat, and patch excerpt for a real commit", %{path: path} do
    sha =
      commit_change(
        path,
        [{"a.txt", "alpha\nbeta\ngamma\n"}, {"b.txt", "one\n"}],
        "two files"
      )

    assert {:ok, capture} = Diff.capture(sha, path)

    assert capture.sha == sha
    assert capture.stats.files == 2
    assert capture.stats.additions == 4
    assert capture.stats.deletions == 0

    paths = Enum.map(capture.files, & &1.path) |> Enum.sort()
    assert paths == ["a.txt", "b.txt"]

    a = Enum.find(capture.files, &(&1.path == "a.txt"))
    assert a.additions == 3
    assert a.deletions == 0

    assert capture.patch_excerpt =~ "diff --git"
    assert capture.patch_excerpt =~ "a.txt"
  end

  test "patch_excerpt is truncated to ~80 lines", %{path: path} do
    big = Enum.map_join(1..400, "\n", &"line #{&1}") <> "\n"
    sha = commit_change(path, [{"big.txt", big}], "fat commit")

    assert {:ok, capture} = Diff.capture(sha, path)

    line_count = capture.patch_excerpt |> String.split("\n") |> length()
    assert line_count <= 80
  end

  test "deletions are counted", %{path: path} do
    sha1 =
      commit_change(
        path,
        [{"c.txt", "one\ntwo\nthree\nfour\n"}],
        "seed"
      )

    refute sha1 == ""

    File.write!(Path.join(path, "c.txt"), "one\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "shrink"], cd: path)
    {sha2_raw, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    sha2 = String.trim(sha2_raw)

    assert {:ok, capture} = Diff.capture(sha2, path)
    assert capture.stats.deletions >= 3
  end

  test "binary-style numstat (- / -) is treated as zero counts", %{path: path} do
    # Tell git to treat the file as binary regardless of contents so we
    # exercise the `-`/`-` parsing branch deterministically across hosts.
    File.write!(Path.join(path, ".gitattributes"), "logo.bin binary\n")
    bin = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(32)
    File.write!(Path.join(path, "logo.bin"), bin)
    {_, 0} = System.cmd("git", ["add", "."], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "add binary"], cd: path)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    sha = String.trim(sha)

    assert {:ok, capture} = Diff.capture(sha, path)
    bin_file = Enum.find(capture.files, &(&1.path == "logo.bin"))
    assert bin_file
    assert bin_file.additions == 0
    assert bin_file.deletions == 0
  end

  test "non-existent sha returns {:error, _} without raising", %{path: path} do
    assert {:error, _reason} = Diff.capture("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", path)
  end

  test "missing worktree returns {:error, _} without raising" do
    bogus = Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}")
    assert {:error, _reason} = Diff.capture("abc123", bogus)
  end

  test "invalid arg shapes return {:error, :invalid_args}" do
    assert {:error, :invalid_args} = Diff.capture(nil, "/tmp")
    assert {:error, :invalid_args} = Diff.capture("abc", nil)
  end
end
