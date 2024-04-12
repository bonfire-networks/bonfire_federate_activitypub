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
  alias Bonfire.Common.Utils
  alias Bonfire.Common.URIs
  alias Bonfire.Common.Extend

  def list do
    repo().many(list_query())
  end

  def list_paginated(opts) do
    repo().many_paginated(list_query(), opts)
  end

  def list_query() do
    from(p in Peer)
    |> order_by(desc: :id)
  end

  def get(canonical_uri) when is_binary(canonical_uri) do
    with %URI{} = instance_url <- URIs.base_url(canonical_uri) do
      do_get(instance_url)
    end
  end

  def get_by_domain(canonical_uri) when is_binary(canonical_uri) do
    from(p in Peer,
      where: p.display_hostname == ^canonical_uri
    )
    # |> repo().maybe_where_ilike("ap_base_uri", canonical_uri, "%//")
    |> repo().single()
  end

  defp do_get(instance_url) do
    repo().single(peer_url_query(instance_url))
  end

  defp create(instance_url, host) do
    get_or_create_instance_circle(host)
    |> debug("circle for instance actors")

    # TODO: maybe Peer should be a mixin so it can have the same ID as the Circle representing it?

    repo().insert(Peer.changeset(%Peer{}, %{ap_base_uri: instance_url, display_hostname: host}))
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

  defp do_get_or_create(canonical_uri) when is_binary(canonical_uri) do
    uri =
      URI.parse(canonical_uri)
      |> debug()

    host =
      URIs.base_domain(uri)
      |> debug()

    if host do
      instance_url =
        "#{uri.scheme}://#{host}"
        |> debug()

      case do_get(instance_url) do
        {:ok, peer} ->
          debug(instance_url, "instance already exists")

          get_or_create_instance_circle(host)
          |> warn(
            "TEMPORARY: create a circle for instance (remove this in future, since doing it when a Peer is first created should be enough)"
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
      module.get_or_create(
        host,
        Bonfire.Boundaries.Fixtures.activity_pub_circle()
      )
    end
  end

  def is_blocked?(peered, block_type \\ :any, opts \\ [])

  def is_blocked?(uri, block_type, opts) when is_binary(uri) do
    get_or_create(uri)
    |> debug(uri)
    ~> is_blocked?(block_type, opts)
  end

  def is_blocked?(%Peer{display_hostname: display_hostname} = peer, block_type, opts) do
    with {:ok, circle} <- get_or_create_instance_circle(display_hostname) do
      Bonfire.Boundaries.Blocks.is_blocked?(circle, block_type, opts)
    end
  end

  def is_blocked?(%Bonfire.Data.ActivityPub.Peered{} = peered, block_type, opts) do
    # just in case
    Bonfire.Federate.ActivityPub.Peered.is_blocked?(peered, block_type, opts)
  end

  def is_blocked?(%Bonfire.Data.AccessControl.Circle{} = circle, block_type, opts) do
    Bonfire.Boundaries.Blocks.is_blocked?(circle, block_type, opts)
  end
end
