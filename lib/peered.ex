defmodule Bonfire.Federate.ActivityPub.Peered do
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Common.Utils
  import Bonfire.Federate.ActivityPub.Integration
  import Ecto.Query
  require Logger

  def get(id) when is_binary(id) do
    if Utils.is_ulid?(id) do
      repo().single(from p in Peered, where: p.id == ^id)
    else
      repo().single(from p in Peered, where: p.canonical_uri == ^id)
    end
  end
  def get(%Peered{} = peered) do
    peered
  end
  def get(%{id: pointer_id, peered: _} = obj) do
    obj |> repo().maybe_preload(:peered) |> Map.get(:peered)
  end
  def get(%{id: pointer_id}) do
    get(pointer_id)
  end
  def get(%{canonical_uri: canonical_uri}) when is_binary(canonical_uri) do
    get(canonical_uri)
  end
  def get(%{"id"=> id}) when is_binary(id) do
    get(id)
  end
  def get(%{"canonicalUrl"=> canonical_uri}) when is_binary(canonical_uri) do
    get(canonical_uri)
  end
  def get(unknown) do
    Logger.warn("Could not get Peered for #{inspect unknown}")
    nil
  end

  def get_canonical_uri(obj_or_id), do: obj_or_id |> get() |> Utils.e(:canonical_uri, nil)

  def save_canonical_uri(%{id: id}, canonical_uri), do: save_canonical_uri(id, canonical_uri)
  def save_canonical_uri(id, canonical_uri) when is_binary(id) and is_binary(canonical_uri) do
    with  {:ok, peer} =  Bonfire.Federate.ActivityPub.Peers.get_or_create(canonical_uri),
    {:ok, peered} <- create(id, peer.id, canonical_uri) do
      {:ok, peered}
    end
  end

  def create(id, peer_id, canonical_uri) do
    repo().upsert(
      %Peered{
        id: id,
        peer_id: peer_id,
        canonical_uri: canonical_uri
      }
    )
  end


end
