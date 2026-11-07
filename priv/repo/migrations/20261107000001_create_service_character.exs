defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.CreateServiceCharacter do
  @moduledoc false
  use Ecto.Migration

  # The instance's federation bot exists from install, rather than being made on first use: reports are delivered to it so that one made while nobody can moderate is still listed later, and making it during a request raced when several made it at once.
  def up do
    Bonfire.Federate.ActivityPub.AdapterUtils.get_or_create_service_character()
  end

  def down, do: nil
end
