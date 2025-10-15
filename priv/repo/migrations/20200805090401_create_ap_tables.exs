defmodule Bonfire.Repo.Migrations.CreateApTables do
  @moduledoc false
  use Ecto.Migration
      @disable_ddl_transaction true

  def up do
    ActivityPub.Migrations.up()
  end

  def down do
    ActivityPub.Migrations.down()
  end
end
