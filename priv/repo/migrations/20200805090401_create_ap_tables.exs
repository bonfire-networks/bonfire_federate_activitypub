defmodule Bonfire.Repo.Migrations.CreateApTables do
  @moduledoc false
  use Ecto.Migration

  def up do
    ActivityPub.Migrations.up()
  end

  def down do
    ActivityPub.Migrations.down()
  end
end
