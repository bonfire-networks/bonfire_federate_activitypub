defmodule Bonfire.Federate.ActivityPub.Instances do
  @moduledoc """
  Federated instances
  Context for `Bonfire.Data.ActivityPub.Peer`
  """
  use Arrows
  import Untangle
  import Bonfire.Federate.ActivityPub
  import Ecto.Query
  alias Bonfire.Data.ActivityPub.Peer
  # alias Bonfire.Common.Utils
  alias Bonfire.Common.URIs
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Types

  def list do
    repo().many(list_query())
  end

  def list_by_domains(canonical_uris) do
    query_by_domain(canonical_uris)
    |> repo().many()
  end

  def list_paginated(opts) do
    repo().many_paginated(list_query(), opts)
  end

  def list_query() do
    from(p in Peer)
    |> order_by(desc: :id)
  end

  def get(id_or_canonical_uri) when is_binary(id_or_canonical_uri) do
    if Types.is_uid?(id_or_canonical_uri) do
      get_by_id(id_or_canonical_uri)
    else
      with %URI{} = instance_url <- URIs.base_url(id_or_canonical_uri) do
        get_by_instance_url(instance_url)
      end
    end
  end

  def get_by_id(id) when is_binary(id) do
    from(p in Peer,
      where: p.id == ^id
    )
    |> repo().single()
  end

  defp query_by_domain(canonical_uri) when is_binary(canonical_uri) do
    from(p in Peer,
      where: p.display_hostname == ^canonical_uri
    )

    # |> repo().maybe_where_ilike("ap_base_uri", canonical_uri, "%//")
  end

  defp query_by_domain(canonical_uri) when is_list(canonical_uri) do
    from(p in Peer,
      where: p.display_hostname in ^canonical_uri
    )
  end

  def get_by_domain(canonical_uri) when is_binary(canonical_uri) do
    query_by_domain(canonical_uri)
    |> repo().single()
  end

  defp get_by_instance_url(instance_url) do
    repo().single(peer_url_query(instance_url))
  end

  defp create(instance_url, host) do
    get_or_create_instance_circle(host)
    |> debug("circle for instance actors")

    # TODO: maybe Peer should be a mixin so it can have the same ID as the Circle representing it?

    with {:ok, peer} <-
           repo().insert(
             Peer.changeset(%Peer{}, %{ap_base_uri: instance_url, display_hostname: host})
           ) do
      Extend.maybe_module(Bonfire.Boundaries.Circles).create_stereotype_circle(peer, :silence_me)

      {:ok, peer}
    end
  end

  defp peer_url_query(url) do
    from(p in Peer,
      where: p.ap_base_uri == ^url
    )
  end

  def get_or_create("https://www.w3.org/ns/activitystreams#Public"), do: nil
  def get_or_create(%{ap_id: canonical_uri}), do: get_or_create(canonical_uri)

  def get_or_create(%{data: %{"id" => canonical_uri}}),
    do: get_or_create(canonical_uri)

  def get_or_create(%{"id" => canonical_uri}), do: get_or_create(canonical_uri)

  def get_or_create(canonical_uri) when is_binary(canonical_uri) do
    if ActivityPub.Utils.has_as_public?(canonical_uri) do
      debug(canonical_uri, "is a public URI, not creating Peer for it")
      nil
    else
      local_instance = Bonfire.Common.URIs.base_url()
      # only create Peer for remote instances
      if !String.starts_with?(canonical_uri, local_instance) do
        do_get_or_create(canonical_uri)
      else
        debug(canonical_uri)
        debug(local_instance)
        error("Local actor was treated as remote")
      end
    end
  end

  defp do_get_or_create(canonical_uri) when is_binary(canonical_uri) do
    uri =
      URI.parse(canonical_uri)
      |> debug()

    host =
      URIs.base_domain(uri)
      |> debug()

    if host do
      #  FIXME: what about instances with a specific port?
      instance_url =
        "#{uri.scheme}://#{host}"
        |> debug()

      # TODO: use get_by_domain instead?
      case get_by_instance_url(instance_url) do
        {:ok, peer} ->
          debug(instance_url, "instance already exists")

          get_or_create_instance_circle(host)
          |> warn(
            "TEMPORARY: create a circle for instance (remove this in future, since doing it when a Peer is first created should be enough)"
          )

          Extend.maybe_module(Bonfire.Boundaries.Circles).get_or_create_stereotype_circle(
            peer,
            :silence_me
          )
          |> warn(
            "TEMPORARY: create a silencing circle for instance (remove this in future, since doing it when a Peer is first created should be enough)"
          )

          {:ok, peer}

        _none ->
          debug(instance_url, "instance unknown, create a `Circle` and `Peer` for it now")

          create(instance_url, host)
      end
    else
      error(canonical_uri, "instance hostname unknown")
    end
  end

  def get_or_create_instance_circle(host) do
    if module = Extend.maybe_module(Bonfire.Boundaries.Circles) do
      with {:ok, instance_circle} <-
             module.get_or_create(
               host,
               Bonfire.Boundaries.Scaffold.Instance.activity_pub_circle()
             ) do
        # module.get_or_create_stereotype_circle(instance_circle, :silence_me)

        {:ok, instance_circle}
      end
    end
  end

  def get_instance_circle(host) do
    if module = Extend.maybe_module(Bonfire.Boundaries.Circles) do
      module.get_by_name(
        host,
        Bonfire.Boundaries.Scaffold.Instance.activity_pub_circle()
      )
    end
  end

  def instance_blocked?(peered, block_type \\ :any, opts \\ [])

  def instance_blocked?(uri, block_type, opts) when is_binary(uri) do
    with {:ok, peer} <- get(uri) do
      instance_blocked?(peer, block_type, opts)
    else
      _ ->
        false
    end
  end

  def instance_blocked?(%Peer{display_hostname: display_hostname} = _peer, block_type, opts) do
    with {:ok, circle} <- get_instance_circle(display_hostname) |> debug("instance_circle") do
      Bonfire.Boundaries.Blocks.is_blocked?(circle, block_type, opts)
    else
      _ ->
        false
    end
  end

  def instance_blocked?(%Bonfire.Data.ActivityPub.Peered{} = peered, block_type, opts) do
    # just in case
    Bonfire.Federate.ActivityPub.Peered.actor_blocked?(peered, block_type, opts)
  end

  def instance_blocked?(%Bonfire.Data.AccessControl.Circle{} = circle, block_type, opts) do
    Bonfire.Boundaries.Blocks.is_blocked?(circle, block_type, opts)
  end
end
