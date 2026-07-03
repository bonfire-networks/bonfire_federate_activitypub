defmodule Bonfire.Federate.ActivityPub.Repo.Migrations.AddPeeredCanonicalUriIndex do
  @moduledoc false
  use Ecto.Migration
  use Needle.Migration.Indexable

  def up do
    Bonfire.Data.ActivityPub.Peered.Migration.add_peered_canonical_uri_index()
  end

  def down do
    Bonfire.Data.ActivityPub.Peered.Migration.drop_peered_canonical_uri_index()
  end
end
