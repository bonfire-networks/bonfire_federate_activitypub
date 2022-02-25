defmodule Bonfire.Federate.ActivityPub.Actors do
  @moduledoc """
  Federated actors
  Context for `Bonfire.Data.ActivityPub.Peered`
  """
  use Arrows
  use Bonfire.Common.Utils
  import Bonfire.Federate.ActivityPub, except: [repo: 0]
  use Bonfire.Repo
  import Where
  alias Bonfire.Data.ActivityPub.Peer
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Federate.ActivityPub.Instances

  def get(id) when is_binary(id) do
    if Utils.is_ulid?(id) do
      repo().single(from(p in Peered) |> where([p], p.id == ^id) |> proload(:peer))
    else
      repo().single(from(p in Peered) |> where([p], p.canonical_uri == ^id) |> proload(:peer))
    end
  end
  def get(%Peered{} = peered) do
    peered
  end
  def get(%{peered: _} = obj) do
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
    warn("Could not get Peered for #{inspect unknown}")
    nil
  end

  def get_canonical_uri(obj_or_id), do: obj_or_id |> get() |> Utils.e(:canonical_uri, nil)

  def save_canonical_uri(%{id: id}, canonical_uri), do: save_canonical_uri(id, canonical_uri)
  def save_canonical_uri(id, canonical_uri) when is_binary(id) and is_binary(canonical_uri) do
    get_or_create(canonical_uri, id)
  end

  def get_or_create(canonical_uri, id \\ nil) when is_binary(canonical_uri) do
    case get(canonical_uri) do
      {:ok, peered} ->
        {:ok, peered}

      _ ->
        with {:ok, peer} <- Instances.get_or_create(canonical_uri) do
          if id,
            do: create(id, peer, canonical_uri),
            else: {:ok, peer}
        end
    end
  end

  def create(id, peer, canonical_uri) do
    repo().upsert(
      %Peered{
        id: id,
        peer: peer,
        peer_id: Utils.ulid(peer),
        canonical_uri: canonical_uri
      }
    )
  end

  def is_blocked?(peered, block_type \\ :any, opts \\ [])

  def is_blocked?(%Peered{} = peered, block_type, opts) do
    peered = peered |> repo().maybe_preload(:peer) #|> debug
    # check if either of instance or actor is blocked
    Instances.is_blocked?(Map.get(peered, :peer), block_type, opts)
      ||
    Bonfire.Boundaries.is_blocked?(peered, block_type, opts)
  end

  def is_blocked?(uri, block_type, opts) when is_binary(uri) do
    get_or_create(uri)
    # ~> debug
    ~> is_blocked?(block_type, opts)
  end

  def is_blocked?(%URI{} = uri, block_type, opts) do
    URI.to_string(uri) |> is_blocked?(block_type, opts)
  end

  def is_blocked?(%Peer{} = peer, block_type, opts) do # fallback to just check the instance if that's all we have
    Instances.is_blocked?(peer, block_type, opts)
  end


end
