defmodule Bonfire.Federate.ActivityPub.Peered do
  @moduledoc """
  Federated actors or objects
  Context for `Bonfire.Data.ActivityPub.Peered`
  """
  use Arrows
  use Bonfire.Common.Utils
  import Bonfire.Federate.ActivityPub, except: [repo: 0]
  use Bonfire.Common.Repo
  import Untangle
  alias Bonfire.Data.ActivityPub.Peer
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Federate.ActivityPub.Instances

  def get(id) when is_binary(id) do
    if Utils.is_ulid?(id) do
      repo().single(
        from(p in Peered)
        |> where([p], p.id == ^id)
        |> proload(:peer)
      )
    else
      repo().single(
        from(p in Peered)
        |> where([p], p.canonical_uri == ^id)
        |> proload(:peer)
      )
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

  def get(%{"id" => id}) when is_binary(id) do
    get(id)
  end

  def get(%{"canonicalUrl" => canonical_uri}) when is_binary(canonical_uri) do
    get(canonical_uri)
  end

  def get(unknown) do
    warn("Could not get Peered for #{inspect(unknown)}")
    nil
  end

  def get_canonical_uri(obj_or_id),
    do: get(obj_or_id) |> Utils.e(:canonical_uri, nil)

  def save_canonical_uri(%{id: id}, canonical_uri),
    do: save_canonical_uri(id, canonical_uri)

  def save_canonical_uri(id, canonical_uri)
      when is_binary(id) and is_binary(canonical_uri) do
    get_or_create(canonical_uri, id)
  end

  defp get_or_create(canonical_uri, id \\ nil) when is_binary(canonical_uri) do
    base_url = Bonfire.Common.URIs.base_url()

    # only create Peer for remote instances
    if not String.starts_with?(canonical_uri, base_url) do
      do_get_or_create(canonical_uri, id)
    else
      warn("Skip creating a Peered for local URI: #{canonical_uri}")

      maybe_username = String.replace_leading(canonical_uri, base_url <> "/pub/actors/", "")

      if not String.contains?(maybe_username, "/"),
        do: Bonfire.Me.Characters.by_username(maybe_username)
    end
  end

  defp do_get_or_create(canonical_uri, id \\ nil)
       when is_binary(canonical_uri) do
    case get(canonical_uri) do
      # found an existing Actor or other Peered object
      {:ok, peered} ->
        {:ok, peered}

      _ ->
        # first we need an instance / Peer
        with {:ok, peer} <- Instances.get_or_create(canonical_uri) do
          if id,
            # create a Peered linked to the ID of the User or Object
            do: create(id, peer, canonical_uri),
            # just return the instance
            else: {:ok, peer}
        end
    end
  end

  def create(id, peer, canonical_uri) do
    repo().insert_or_ignore(%Peered{
      id: id,
      peer: peer,
      peer_id: Utils.ulid(peer),
      canonical_uri: canonical_uri
    })
  end

  def is_blocked?(peered, block_type \\ :any, opts \\ [])

  def is_blocked?(%Peered{} = peered, block_type, opts) do
    # |> debug
    peered = repo().maybe_preload(peered, :peer)
    peer = Map.get(peered, :peer)
    # check if either of instance or actor is blocked
    Instances.is_blocked?(peer, block_type, opts)
    |> info("firstly, instance blocked? #{inspect(peer)}") ||
      Bonfire.Boundaries.Blocks.is_blocked?(peered, block_type, opts)
      |> info("actor blocked? #{inspect(peered)}")
  end

  def is_blocked?(uri, block_type, opts) when is_binary(uri) do
    uri
    |> debug()
    |> get_or_create()
    # ~> debug
    ~> is_blocked?(block_type, opts)
  end

  def is_blocked?(%URI{} = uri, block_type, opts) do
    URI.to_string(uri) |> is_blocked?(block_type, opts)
  end

  # fallback to just check the instance if that's all we have
  def is_blocked?(%Peer{} = peer, block_type, opts) do
    Instances.is_blocked?(peer, block_type, opts)
    |> info("instance blocked? ")
  end

  # fallback to just check the instance if that's all we have
  def is_blocked?(%{id: _} = character, block_type, opts) do
    Bonfire.Boundaries.Blocks.is_blocked?(character, block_type, opts)
    |> info("character blocked? ")
  end
end
