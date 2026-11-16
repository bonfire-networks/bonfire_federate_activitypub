defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.FixCorruptedApObjectPointers do
  use Ecto.Migration

  def up do
    Bonfire.Federate.ActivityPub.RepairCorruptedActorPointers.run(repo())
  end

  def down, do: :ok
end
