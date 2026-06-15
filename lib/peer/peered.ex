defmodule Bonfire.Federate.ActivityPub.Peered do
  @moduledoc """
  Federated actors or objects
  Context for `Bonfire.Data.ActivityPub.Peered`

  Since `Peered` is a mixin whose `id` is the object's pointer id, associations injected via config (in `config/bonfire_data.exs`) that key on that id apply to the host — e.g. `:encircles` (circle memberships, where `Encircle.subject_id == id`) resolves to the objects's memberships, used when an actor/instance is silenced or ghosted into a circle.
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
      get_by_uid(id)
    else
      get_by_uri(id)
    end
  end

  def get(%Peered{} = peered) do
    peered
  end

  def get(%{peered: _} = obj) do
    obj |> repo().maybe_preload(:peered) |> Map.get(:peered)
  end

  def get(%{pointer_id: pointer_id}) when is_binary(pointer_id) do
    get_by_uid(pointer_id)
  end

  # AP Actor structs use ap_id (URL) for lookup; their `id` field is a UUID not a Needle UID
  def get(%ActivityPub.Actor{ap_id: ap_id}) when is_binary(ap_id) do
    get_by_uri(ap_id)
  end

  def get(%{id: pointer_id}) do
    get_by_uid(pointer_id)
  end

  def get(%{canonical_uri: canonical_uri}) when is_binary(canonical_uri) do
    get_by_uri(canonical_uri)
  end

  def get(%{"id" => id}) when is_binary(id) do
    get(id)
  end

  def get(%{"canonicalUrl" => canonical_uri}) when is_binary(canonical_uri) do
    get_by_uri(canonical_uri)
  end

  def get(%URI{host: host} = uri) when not is_nil(host) do
    get_by_uri(URI.to_string(uri))
  end

  def get(unknown) do
    warn("Could not get Peered for #{inspect(unknown)}")
    nil
  end

  @doc "Returns `%Peered{}` if resolvable, otherwise `nil`. Used to preload once before block+allowlist checks. Prefers a `Peered` pre-resolved for the whole recipient set (`opts[:resolved][:peered_by_urls]`, built by `BoundariesMRF.filter/2`) to avoid per-actor n+1."
  def get_or_nil(subject, opts \\ []) do
    case preloaded_peered(subject, opts) || get(subject) do
      {:ok, peered} -> peered
      %Peered{} = peered -> peered
      _ -> nil
    end
  end

  # look the subject's canonical URI up in the pre-resolved map, when present
  defp preloaded_peered(subject, opts) do
    case peered_uri_key(subject) do
      uri when is_binary(uri) ->
        case ed(opts, :resolved, :peered_by_urls, uri, nil) do
          %Peered{} = peered -> {:ok, peered}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp peered_uri_key(uri) when is_binary(uri),
    do: if(Types.is_uid?(uri), do: nil, else: uri)

  defp peered_uri_key(%ActivityPub.Actor{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp peered_uri_key(%URI{host: host} = uri) when not is_nil(host), do: URI.to_string(uri)
  defp peered_uri_key(%{canonical_uri: uri}) when is_binary(uri), do: uri
  defp peered_uri_key(_), do: nil

  def get_by_uid(id) when is_binary(id) do
    repo().single(
      from(p in Peered)
      |> where([p], p.id == ^id)
      |> proload(:peer)
    )
  end

  def get_by_uri(id) when is_binary(id) do
    repo().single(
      from(p in Peered)
      |> where([p], p.canonical_uri == ^id)
      |> proload(:peer)
    )
  end

  def list do
    repo().many(
      from(p in Peered)
      |> proload(:peer)
    )
  end

  @doc """
  Filters a query of pointable objects by federation origin, via the `Peered` mixin (whose `id` is the
  object's pointer id): `:local` keeps objects with no `Peered` row, `:remote` keeps those with one,
  `:all`/`nil` is a no-op. The query must have a `:main_object` named binding (the convention for the
  object table). Users have their own variant (`Bonfire.Me.Users.Queries`) since locality lives on
  `character.peered`, but the local/remote semantics are shared here.
  """
  def filter_by_origin(query, origin) when origin in [:local, :remote] do
    query =
      reusable_join(query, :left, [main_object: o], peered in Peered,
        on: peered.id == o.id,
        as: :peered
      )

    case origin do
      :local -> where(query, [peered: p], is_nil(p.id))
      :remote -> where(query, [peered: p], not is_nil(p.id))
    end
  end

  def filter_by_origin(query, _all), do: query

  @doc "Batch-load `Peered` records for a list of canonical URIs (to pre-resolve recipients and avoid n+1 in the MRF filter)."
  def list_by_canonical_uris(canonical_uris) when is_list(canonical_uris) do
    case canonical_uris |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        []

      uris ->
        repo().many(
          from(p in Peered)
          |> where([p], p.canonical_uri in ^uris)
          |> proload(:peer)
        )
    end
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
      # TODO: avoid calling this for local ones?
      warn(canonical_uri, "We do not create a Peered for local URI")
      {:error, :local}

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

  def actor_allowlisted?(peered_or_uri, opts \\ [])

  def actor_allowlisted?(subjects, opts) when is_list(subjects) do
    Enum.any?(subjects, &actor_allowlisted?(&1, opts))
  end

  def actor_allowlisted?(%Peered{} = peered, opts) do
    peered = repo().maybe_preload(peered, :peer)
    is_allowlisted_peer_or_peered?(peered, opts)
  end

  def actor_allowlisted?(%Peer{} = peer, opts) do
    Instances.instance_allowlisted?(peer, opts)
  end

  def actor_allowlisted?(id_or_uri, opts) when is_binary(id_or_uri) do
    if is_uid?(id_or_uri) do
      with {:ok, peered} <- get(id_or_uri) do
        actor_allowlisted?(peered, opts)
      else
        _ -> false
      end
    else
      # prefer a pre-resolved `Peered` (`opts[:resolved]`, built by `BoundariesMRF.filter/2`) to avoid
      # per-actor n+1; fall back to a single query when not provided
      preloaded = ed(opts, :resolved, :peered_by_urls, id_or_uri, nil)

      with {:ok, peered} <- (preloaded && {:ok, preloaded}) || get(id_or_uri) do
        actor_allowlisted?(peered, opts)
      else
        _ ->
          info(
            id_or_uri,
            "no existing Peered record for URI, falling back to instance allowlist check"
          )

          Instances.instance_allowlisted?(id_or_uri, opts)
          |> info("instance_allowlisted? result for #{id_or_uri}")
      end
    end
  end

  def actor_allowlisted?(%URI{} = uri, opts) do
    URI.to_string(uri) |> actor_allowlisted?(opts)
  end

  def actor_allowlisted?(%{peered: _} = object, opts) do
    object = repo().preload(object, [peered: [:peer]], force: true)
    peered = Map.get(object, :peered) || %{}
    peered = repo().maybe_preload(peered, :peer)
    is_allowlisted_peer_or_peered?(peered, opts)
  end

  def actor_allowlisted?(_, _opts), do: false

  defp is_allowlisted_peer_or_peered?(peered, _opts) when peered in [nil, %{}], do: false

  defp is_allowlisted_peer_or_peered?(%{peer: peer} = peered, opts)
       when peer not in [nil, %{}] do
    Instances.instance_allowlisted?(peer, opts)
    |> debug("Instance allowlisted? #{inspect(peer)}") ||
      Bonfire.Boundaries.Allowlist.is_allowlisted?(peered, opts)
      |> debug("Actor directly allowlisted? #{inspect(peered)}")
  end

  defp is_allowlisted_peer_or_peered?(peered, opts) do
    debug(peered, "no instance associated with actor, checking actor directly")
    Bonfire.Boundaries.Allowlist.is_allowlisted?(peered, opts)
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
      # prefer a `Peered` pre-resolved for the whole recipient set (avoids per-actor n+1 in the MRF
      # filter); fall back to a single query when not provided (non-MRF callers)
      preloaded = ed(opts, :resolved, :peered_by_urls, id_or_uri, nil)

      with {:ok, peered} <-
             (preloaded && {:ok, preloaded}) ||
               get(id_or_uri) |> debug("existing Peered for URI") do
        actor_blocked?(peered, block_type, opts)
      else
        _ ->
          info(
            id_or_uri,
            "no existing Peered record for URI, falling back to character + instance block check with block_type=#{inspect(block_type)}"
          )

          character_blocked =
            case get_by_uri(id_or_uri)
                 |> info("get by canonical_uri result") do
              {:ok, peered} ->
                actor_blocked?(peered, block_type, opts)

              _ ->
                case Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(id_or_uri)
                     |> info("get_character_by_ap_id result") do
                  {:ok, character} ->
                    Bonfire.Boundaries.Blocks.is_blocked?(character, block_type, opts)
                    |> info("is_blocked? for character #{id(character)}")

                  _ ->
                    false
                end
            end

          # only do the remote instance-block check for remote subjects — a local actor (e.g. a bare
          # username served via /pub/actors/:username) isn't on a blockable remote instance
          (character_blocked ||
             (not Bonfire.Federate.ActivityPub.AdapterUtils.local_subject?(id_or_uri) and
                Instances.instance_blocked?(id_or_uri, block_type, opts)))
          |> info("blocked? result for #{id_or_uri}")
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
