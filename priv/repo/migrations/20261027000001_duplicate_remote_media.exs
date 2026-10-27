defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.DuplicateRemoteMedia do
  use Ecto.Migration

  # the copies of remote media that each `Update` of it made (eg. PeerTube's, sent each time a video gets views), keeping the earliest
  def up() do
    Bonfire.Federate.ActivityPub.DataMigrations.DuplicateRemoteMedia.up()
  end

  def down, do: :ok
end
