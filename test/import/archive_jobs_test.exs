defmodule Bonfire.Federate.ActivityPub.Import.ArchiveJobsTest do
  @moduledoc "The account archive (Mastodon's or Bonfire's) and the ActivityPub outbox ops belong to the federation extension, and the archive turns what the person picked into jobs for the import framework, each op done by the extension that owns it."
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :backend

  alias Bonfire.Common.Import
  alias Bonfire.Federate.ActivityPub.Import.Archive
  alias Bonfire.Federate.ActivityPub.Import.OutboxOps

  # the trimmed real Mastodon archive the account import tests use
  @fixture Path.join(File.cwd!(), "extensions/bonfire_ui_social/test/fixtures/mastodon_archive")

  setup do
    # the archive's old server is offline: materializing the outbox checks whether its author can still be fetched
    Tesla.Mock.mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)
    :ok
  end

  defp archive_zip! do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-archive.zip")

    entries =
      for file <- Path.wildcard(Path.join(@fixture, "**/*")), File.regular?(file) do
        {String.to_charlist(Path.relative_to(file, @fixture)), File.read!(file)}
      end

    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "the outbox ops and the account archive are the federation extension's" do
    assert Import.op_handler("outbox_creations_import") == OutboxOps
    assert Import.op_handler("outbox_import") == OutboxOps
    assert Import.archive_source(:archive) == Archive
  end

  test "materializing an archive returns a job for each picked item, by op" do
    user = fake_user!()

    assert {:ok, staged} = Archive.stage(archive_zip!())
    on_exit(fn -> File.rm_rf(staged.dir) end)

    assert {:ok, %{jobs: jobs}} =
             Archive.materialize(staged, [:posts, :likes, :bookmarks], current_user: user)

    assert jobs |> Enum.map(& &1.op) |> Enum.uniq() |> Enum.sort() ==
             ["bookmarks_import", "likes_import", "outbox_creations_import"]
  end
end
