defmodule Bonfire.Repo.Migrations.CreateObanTables do
  @moduledoc false
  use Ecto.Migration

  def up do
    Oban.Migrations.up()
  end

  def down do
    Oban.Migrations.down(version: 1)
  end
end
