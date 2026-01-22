defmodule Bonfire.Repo.Migrations.CreateApTables do
  @moduledoc false
  use Ecto.Migration
  
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.up()
  end

  def down do
    ActivityPub.Migrations.down()
  end
end
