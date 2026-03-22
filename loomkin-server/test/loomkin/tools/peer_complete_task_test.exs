defmodule Loomkin.Tools.PeerCompleteTaskTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.PeerCompleteTask

  describe "verify_files_changed/2" do
    test "returns empty list when no files claimed" do
      assert PeerCompleteTask.verify_files_changed([], "/tmp") == []
    end

    test "returns empty list when project_path is nil" do
      assert PeerCompleteTask.verify_files_changed(["some/file.ex"], nil) == []
    end

    test "returns empty list when all claimed files exist" do
      # Create a temporary file to verify against
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "peer_complete_task_test_#{:rand.uniform(100_000)}.txt")
      File.write!(test_file, "test content")

      try do
        relative_path = Path.relative_to(test_file, tmp_dir)
        assert PeerCompleteTask.verify_files_changed([relative_path], tmp_dir) == []
      after
        File.rm(test_file)
      end
    end

    test "returns warnings for files that don't exist" do
      tmp_dir = System.tmp_dir!()
      fake_file = "definitely_not_a_real_file_#{:rand.uniform(100_000)}.ex"

      warnings = PeerCompleteTask.verify_files_changed([fake_file], tmp_dir)

      assert length(warnings) == 1
      assert hd(warnings) =~ fake_file
      assert hd(warnings) =~ "not found on disk"
    end

    test "handles mix of existing and non-existing files" do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "peer_complete_real_#{:rand.uniform(100_000)}.txt")
      File.write!(test_file, "test content")

      try do
        relative_path = Path.relative_to(test_file, tmp_dir)
        fake_file = "no_such_file_#{:rand.uniform(100_000)}.ex"

        warnings =
          PeerCompleteTask.verify_files_changed([relative_path, fake_file], tmp_dir)

        assert length(warnings) == 1
        assert hd(warnings) =~ fake_file
      after
        File.rm(test_file)
      end
    end

    test "filters out empty strings and nils" do
      tmp_dir = System.tmp_dir!()
      assert PeerCompleteTask.verify_files_changed(["", nil], tmp_dir) == []
    end
  end
end
