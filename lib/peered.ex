defmodule Bonfire.Federate.ActivityPub.Peered do
  alias Bonfire.Data.ActivityPub.Peered
  import Bonfire.Federate.ActivityPub.Integration
  import Ecto.Query


  def save_canonical_uri(id, canonical_uri) when is_binary(id) and is_binary(canonical_uri) do
    with  {:ok, peer} =  Bonfire.Federate.ActivityPub.Peers.get_or_create(canonical_uri),
    {:ok, _peered} <- create(id, peer.id, canonical_uri) do
      :ok
    end
  end

  def create(id, peer_id, canonical_uri) do
    repo().insert(
      %Peered{
        id: id,
        peer_id: peer_id,
        canonical_uri: canonical_uri
      }
    )
  end


end
