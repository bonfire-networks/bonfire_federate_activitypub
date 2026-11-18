defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.OwnActorRemoteCopies do
  use Ecto.Migration

  # copies of our own actors stored as remote objects, which their URLs found instead of the actors (eg. every `Join` to a group failing)
  def up() do
    # the migration's own repo, so the cleanup acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Federate.ActivityPub.DataMigrations.OwnActorRemoteCopies,
      repo: repo()
    )
  end

  def down, do: :ok
end
