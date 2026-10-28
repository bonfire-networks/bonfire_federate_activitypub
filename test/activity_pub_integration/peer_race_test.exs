defmodule Bonfire.Federate.ActivityPub.PeerRaceTest do
  @moduledoc """
  Several remote actors of a new instance made at once (one job each) get the same `Peer`. Each reads the instance's `Peer`, finds none, and makes it, so all but one hit the unique index on `ap_base_uri` (`bonfire_data_activity_pub_peer_ap_base_uri_index`): the violation raised, and the transaction creating the actor was lost with it. The loser reads the `Peer` that won instead.

  Committed data, with each task on a connection of its own: the sandbox serialises the transactions of one connection, which would hide the race.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Ecto.Query

  @moduletag :federation
  @moduletag db_sandbox: false

  alias Bonfire.Data.ActivityPub.Peer
  alias Bonfire.Federate.ActivityPub.Instances

  test "actors of a new instance made at once get one Peer, and none raises" do
    host = "race-#{System.unique_integer([:positive])}.example"

    on_exit(fn ->
      repo().delete_all(from(p in Peer, where: p.display_hostname == ^host))
    end)

    results =
      1..8
      |> Task.async_stream(
        fn i ->
          try do
            Instances.get_or_create("https://#{host}/users/user#{i}")
          rescue
            e -> {:raised, e.__struct__}
          end
        end,
        max_concurrency: 8,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    failed = Enum.reject(results, &match?({:ok, %Peer{}}, &1))
    assert failed == [], "#{length(failed)} of 8 failed: #{inspect(failed, limit: 3)}"

    assert results |> Enum.map(fn {:ok, peer} -> peer.id end) |> Enum.uniq() |> length() == 1,
           "more than one Peer was made for #{host}"

    assert repo().aggregate(from(p in Peer, where: p.display_hostname == ^host), :count) == 1
  end
end
