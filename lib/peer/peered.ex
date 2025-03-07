defmodule Bonfire.Federate.ActivityPub.Peered do
  @moduledoc """
  Federated actors or objects
  Context for `Bonfire.Data.ActivityPub.Peered`
  """
  use Arrows
  use Bonfire.Common.Utils
  # import Bonfire.Federate.ActivityPub, except: [repo: 0]
  use Bonfire.Common.Repo
  import Untangle
  alias Bonfire.Data.ActivityPub.Peer
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Federate.ActivityPub.Instances

  def get(id) when is_binary(id) do
    if Types.is_uid?(id) do
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

  def list do
    repo().many(
      from(p in Peered)
      |> proload(:peer)
    )
  end

  def get_canonical_uri(obj_or_id),
    do: get(obj_or_id) |> e(:canonical_uri, nil)

  def save_canonical_uri(object_or_actor, canonical_uri, opts \\ [])

  def save_canonical_uri(%{id: id}, canonical_uri, opts),
    do: save_canonical_uri(id, canonical_uri, opts)

  def save_canonical_uri(id, canonical_uri, opts)
      when is_binary(id) and is_binary(canonical_uri) do
    get_or_create(canonical_uri, Keyword.put(opts, :id, id))
  end

  defp get_or_create(canonical_uri, opts \\ []) when is_binary(canonical_uri) do
    base_url = Bonfire.Common.URIs.base_url()

    # only create Peer for remote instances
    if not String.starts_with?(canonical_uri, base_url) do
      do_get_or_create(canonical_uri, opts[:id], opts[:type])
    else
      error(canonical_uri, "We do not create a Peered for local URI")

      # maybe_username = String.replace_leading(canonical_uri, base_url <> "/pub/actors/", "")

      # if not String.contains?(maybe_username, "/"),
      #   do: Bonfire.Me.Characters.by_username(maybe_username)
    end
  end

  defp do_get_or_create(canonical_uri, id, type)
       when is_binary(canonical_uri) do
    case get(canonical_uri) do
      {:ok, peered} ->
        debug("found an existing Actor or other Peered object")

        if type == :actor and id,
          do:
            add_to_instance_circle(peered, canonical_uri)
            |> warn(
              "TEMPORARY: adding user to instance circle for instance (remove this in future, since doing it when a Peer is first created should be enough)"
            )

        {:ok, peered}

      _ ->
        debug(canonical_uri, "first we need an Instance / Peer")

        with {:ok, peer} <- Instances.get_or_create(canonical_uri) do
          if id do
            debug(peer, "now create a Peered linked to the ID of the User or Object")

            if type == :actor, do: add_to_instance_circle(id, canonical_uri)

            create(id, peer, canonical_uri)
          else
            debug("just return the Instance / Peer")
            {:ok, peer}
          end
        end
    end
  end

  defp add_to_instance_circle(id_or_peered, canonical_uri) do
    if module = maybe_module(Bonfire.Boundaries.Circles) do
      host = URIs.base_domain(canonical_uri)

      with {:ok, instance_circle} <- Instances.get_or_create_instance_circle(host) do
        module.add_to_circles(id_or_peered, instance_circle)
      end
    end
    |> debug()
  end

  defp create(id, peer, canonical_uri) do
    repo().insert_or_ignore(%Peered{
      id: id,
      peer: peer,
      peer_id: Types.uid(peer),
      canonical_uri: canonical_uri
    })
  end

  def actor_blocked?(peered, block_type \\ :any, opts \\ [])

  def actor_blocked?(%Peered{} = peered, block_type, opts) do
    # |> debug
    peered = repo().maybe_preload(peered, :peer)
    # check if either of instance or actor is blocked
    is_blocked_peer_or_peered?(peered, block_type, opts)
  end

  # just check the instance if that's all we have
  def actor_blocked?(%Peer{} = peer, block_type, opts) do
    Instances.instance_blocked?(peer, block_type, opts)
    |> info("we got an instance instead - blocked? ")
  end

  def actor_blocked?(id_or_uri, block_type, opts) when is_binary(id_or_uri) do
    if is_uid?(id_or_uri) do
      with {:ok, peered} <- get(id_or_uri) |> debug("existing Peered") do
        actor_blocked?(peered, block_type, opts)
      else
        other ->
          error(other, "could not find a Peered, maybe it's just a local user?")
          Bonfire.Boundaries.Blocks.is_blocked?(id_or_uri, block_type, opts)
      end
    else
      with {:ok, peered} <- get_or_create(id_or_uri, opts) |> debug("Peered found or created?") do
        actor_blocked?(peered, block_type, opts)
      else
        other ->
          error(other, "could not find or create a Peered, assuming not blocked")
          false
      end
    end
  end

  def actor_blocked?(%URI{} = uri, block_type, opts) do
    URI.to_string(uri) |> actor_blocked?(block_type, opts)
  end

  def actor_blocked?(%{peered: _} = object, block_type, opts) do
    # FIXME: why force?
    object =
      repo().preload(object, [peered: [:peer]], force: true)

    # |> debug("fooooobj")

    # opts
    # |> debug("fooooopts")

    peered = Map.get(object, :peered) || %{}
    peered = repo().maybe_preload(peered, :peer)
    # check if either of instance or actor is blocked
    is_blocked_peer_or_peered?(peered, block_type, opts)
  end

  # fallback to just check the instance if that's all we have
  def actor_blocked?(%ActivityPub.Actor{pointer_id: id} = _actor, block_type, opts) do
    if id,
      do:
        Bonfire.Boundaries.Blocks.is_blocked?(id, block_type, opts)
        |> info("Actor blocked? "),
      else: debug(nil, "no pointer to check for Actor")
  end

  def actor_blocked?(%{id: _} = character, block_type, opts) do
    Bonfire.Boundaries.Blocks.is_blocked?(character, block_type, opts)
    |> info("character blocked? ")
  end

  def actor_blocked?(list, block_type, opts) when is_list(list) do
    true in Enum.map(list, &actor_blocked?(&1, block_type, opts))
  end

  def actor_blocked?(_, _, _) do
    nil
  end

  # defp is_blocked_peer_or_peered?(peer, peered, block_type, opts) do
  #   (not is_nil(peer) and Instances.instance_blocked?(peer, block_type, opts))
  #   |> debug("firstly, check if instance blocked? #{inspect(peer)}") ||
  #     (peered not in [nil, %{}] and
  #        Bonfire.Boundaries.Blocks.is_blocked?(peered, block_type, opts))
  #     |> debug("now check if actor blocked? #{inspect(peered)}")
  # end

  defp is_blocked_peer_or_peered?(peered, _block_type, _opts)
       when peered in [nil, %{}] do
    debug(peered, "no actor provided")
    false
  end

  defp is_blocked_peer_or_peered?(%{peer: peer} = peered, block_type, opts)
       when peer not in [nil, %{}] do
    if Instances.instance_blocked?(peer, block_type, opts) do
      true
      |> debug("Instance blocked: #{inspect(peer)}")
    else
      Bonfire.Boundaries.Blocks.is_blocked?(peered, block_type, opts)
      |> debug("Actor blocked? #{inspect(peered)}")
    end
  end

  defp is_blocked_peer_or_peered?(peered, block_type, opts) do
    debug(peered, "no instance associated with actor")

    Bonfire.Boundaries.Blocks.is_blocked?(peered, block_type, opts)
    |> debug("Actor blocked? #{inspect(peered)}")
  end
end
