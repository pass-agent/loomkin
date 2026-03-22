defmodule Loomkin.RepoIntel.WatcherTest do
  use ExUnit.Case, async: false

  alias Loomkin.RepoIntel.Watcher

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Create a small project structure
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), """
    defmodule App do
      def hello, do: :world
    end
    """)

    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Mix do end\n")

    # Ensure ETS table exists for the index
    if :ets.whereis(:loomkin_repo_index) == :undefined do
      :ets.new(:loomkin_repo_index, [:named_table, :set, :public, read_concurrency: true])
    end

    %{tmp_dir: tmp_dir}
  end

  describe "parse_gitignore/1" do
    test "parses basic patterns" do
      content = """
      # comments are ignored
      _build
      deps
      *.beam

      node_modules/
      """

      patterns = Watcher.parse_gitignore(content)
      assert length(patterns) == 4
      assert Enum.all?(patterns, &is_struct(&1, Regex))
    end

    test "ignores empty lines and comments" do
      content = """
      # This is a comment

      _build
      """

      patterns = Watcher.parse_gitignore(content)
      assert length(patterns) == 1
    end

    test "compiled patterns match correctly" do
      content = """
      _build
      *.beam
      node_modules
      """

      patterns = Watcher.parse_gitignore(content)

      # _build should match _build anywhere in the path
      assert Enum.any?(patterns, &Regex.match?(&1, "_build"))
      assert Enum.any?(patterns, &Regex.match?(&1, "some/_build"))
      assert Enum.any?(patterns, &Regex.match?(&1, "_build/lib/thing"))

      # *.beam should match .beam files
      assert Enum.any?(patterns, &Regex.match?(&1, "lib/app.beam"))
      refute Enum.any?(patterns, &Regex.match?(&1, "lib/app.ex"))
    end
  end

  describe "should_process? (via events)" do
    test "skips .git directory paths" do
      # Start a separate, non-globally-registered watcher
      {:ok, pid} =
        GenServer.start_link(Watcher, [],
          name: :"watcher_skip_test_#{:erlang.unique_integer([:positive])}"
        )

      # Simulate starting a watch
      GenServer.call(pid, {:watch, "/tmp/test-project"})

      # Send a .git event — should be filtered
      send(pid, {:file_event, nil, {"/tmp/test-project/.git/objects/abc", [:modified]}})
      status = GenServer.call(pid, :status)
      assert status.pending_changes == 0

      # Send a normal file event — should be tracked
      send(pid, {:file_event, nil, {"/tmp/test-project/lib/app.ex", [:modified]}})
      status = GenServer.call(pid, :status)
      assert status.pending_changes == 1

      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "returns initial status with no watching" do
      {:ok, pid} =
        GenServer.start_link(Watcher, [],
          name: :"watcher_status_test_#{:erlang.unique_integer([:positive])}"
        )

      status = GenServer.call(pid, :status)
      assert status.watching == false
      assert status.project_path == nil
      assert status.pending_changes == 0

      GenServer.stop(pid)
    end
  end

  describe "debouncing" do
    test "collects multiple events before processing" do
      {:ok, pid} =
        GenServer.start_link(Watcher, [],
          name: :"watcher_debounce_test_#{:erlang.unique_integer([:positive])}"
        )

      # Set up a project path manually via watch
      GenServer.call(pid, {:watch, "/tmp/test-debounce"})

      # Simulate rapid file events (the watcher would normally receive these from FileSystem)
      send(pid, {:file_event, nil, {"/tmp/test-debounce/lib/a.ex", [:modified]}})
      send(pid, {:file_event, nil, {"/tmp/test-debounce/lib/b.ex", [:modified]}})
      send(pid, {:file_event, nil, {"/tmp/test-debounce/lib/c.ex", [:created]}})

      # Check pending changes accumulated
      status = GenServer.call(pid, :status)
      assert status.pending_changes == 3

      GenServer.stop(pid)
    end
  end

  describe "gitignore filtering" do
    test "skips files matching gitignore patterns", %{tmp_dir: tmp_dir} do
      # Write a .gitignore
      File.write!(Path.join(tmp_dir, ".gitignore"), """
      _build
      deps
      *.beam
      """)

      {:ok, pid} =
        GenServer.start_link(Watcher, [],
          name: :"watcher_gitignore_test_#{:erlang.unique_integer([:positive])}"
        )

      GenServer.call(pid, {:watch, tmp_dir})

      # Simulate events for files that should be filtered
      send(pid, {:file_event, nil, {Path.join(tmp_dir, "_build/lib/app.beam"), [:modified]}})
      send(pid, {:file_event, nil, {Path.join(tmp_dir, "deps/jason/lib.ex"), [:modified]}})
      send(pid, {:file_event, nil, {Path.join(tmp_dir, "lib/app.beam"), [:created]}})

      # These should be ignored — pending_changes should be 0
      status = GenServer.call(pid, :status)
      assert status.pending_changes == 0

      # But a normal file should be tracked
      send(pid, {:file_event, nil, {Path.join(tmp_dir, "lib/new.ex"), [:created]}})
      status = GenServer.call(pid, :status)
      assert status.pending_changes == 1

      GenServer.stop(pid)
    end
  end

  describe "event classification" do
    test "classifies delete events" do
      {:ok, pid} =
        GenServer.start_link(Watcher, [],
          name: :"watcher_classify_test_#{:erlang.unique_integer([:positive])}"
        )

      GenServer.call(pid, {:watch, "/tmp/test-classify"})

      send(pid, {:file_event, nil, {"/tmp/test-classify/lib/deleted.ex", [:removed]}})

      status = GenServer.call(pid, :status)
      assert status.pending_changes == 1

      GenServer.stop(pid)
    end
  end
end
