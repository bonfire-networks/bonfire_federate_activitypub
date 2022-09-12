defmodule Bonfire.Federate.ActivityPub.Migrations do
  use Ecto.Migration
  # import Pointers.Migration

  defp map(:up) do
    quote do
      require Bonfire.Data.ActivityPub.Actor.Migration
      require Bonfire.Data.ActivityPub.Peer.Migration
      require Bonfire.Data.ActivityPub.Peered.Migration
      Bonfire.Data.ActivityPub.Actor.Migration.migrate_actor()
      Bonfire.Data.ActivityPub.Peer.Migration.migrate_peer()
      Bonfire.Data.ActivityPub.Peered.Migration.migrate_peered()
    end
  end

  defp map(:down) do
    quote do
      require Bonfire.Data.ActivityPub.Actor.Migration
      require Bonfire.Data.ActivityPub.Peer.Migration
      require Bonfire.Data.ActivityPub.Peered.Migration
      Bonfire.Data.ActivityPub.Peered.Migration.migrate_peered()
      Bonfire.Data.ActivityPub.Peer.Migration.migrate_peer()
      Bonfire.Data.ActivityPub.Actor.Migration.migrate_actor()
    end
  end

  defmacro migrate_activity_pub() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(map(:up)),
        else: unquote(map(:down))
    end
  end

  defmacro migrate_activity_pub(dir), do: map(dir)
end
