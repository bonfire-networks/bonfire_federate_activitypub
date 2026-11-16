defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.DuplicateRemoteMedia do
  use Ecto.Migration

  # the copies of remote media that each `Update` of it made (eg. PeerTube's, sent each time a video gets views), keeping the earliest
  def up() do
    # the migration's own repo, so the cleanup acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Federate.ActivityPub.DataMigrations.DuplicateRemoteMedia,
      repo: repo()
    )
  end

  def down, do: :ok
end
