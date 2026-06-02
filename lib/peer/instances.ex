defmodule Bonfire.Federate.ActivityPub.Instances do
  @moduledoc """
  Federated instances
  Context for `Bonfire.Data.ActivityPub.Peer`
  """
  use Arrows
  import Untangle
  import Bonfire.Federate.ActivityPub
  use Bonfire.Common.E
  import Ecto.Query
  alias Bonfire.Data.ActivityPub.Peer
  alias Bonfire.Common.Utils
  alias Bonfire.Common.URIs
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Types

  @doc "Counts all known federated instances."
  def count do
    repo().aggregate(from(p in Peer), :count)
  end

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
    cond do
      Types.is_uid?(id_or_canonical_uri) ->
        get_by_id(id_or_canonical_uri)

      # not a uid and not a `scheme://…` URL → not an instance canonical URI (e.g. a bare username or
      # a `user@host` actor handle). Don't try to derive a host from it.
      not String.contains?(id_or_canonical_uri, "://") ->
        error(id_or_canonical_uri, "not a valid instance ID or canonical URI")

      true ->
        with instance_url when is_binary(instance_url) <-
               URIs.base_url(id_or_canonical_uri)
               |> info("Instances.get base_url for #{id_or_canonical_uri}") do
          get_by_instance_url(instance_url)
          |> info("Instances.get by_instance_url #{instance_url}")
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
    # TODO: maybe Peer should be a mixin so it can have the same ID as the Circle representing it?

    with {:ok, peer} <-
           repo().insert(
             Peer.changeset(%Peer{}, %{ap_base_uri: instance_url, display_hostname: host})
           ),
         {:ok, _instance_circle} <- get_or_create_instance_circle(host),
         {:ok, _stereo} <-
           Utils.maybe_apply(
             Bonfire.Boundaries.Circles,
             :get_or_create_stereotype_circle,
             [
               peer,
               :silence_me
             ],
             fallback_return: {:ok, nil}
           ) do
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
    circle_type =
      Utils.maybe_apply(Bonfire.Boundaries.Scaffold.Instance, :activity_pub_circle, [],
        fallback_return: nil
      )

    if(circle_type,
      do:
        Utils.maybe_apply(
          Bonfire.Boundaries.Circles,
          :get_or_create,
          [host, circle_type],
          fallback_return: nil
        )
    ) || {:ok, nil}
  end

  def get_instance_circle(host) do
    circle_type =
      Utils.maybe_apply(Bonfire.Boundaries.Scaffold.Instance, :activity_pub_circle, [],
        fallback_return: nil
      )

    if(circle_type,
      do:
        Utils.maybe_apply(
          Bonfire.Boundaries.Circles,
          :get_by_name,
          [host, circle_type],
          fallback_return: nil
        )
    )
  end

  @doc "Batch version of `get_instance_circle/1`: returns a `%{host => circle}` map for a list of hosts (to pre-resolve allowlist circles and avoid n+1 in the MRF filter)."
  def get_instance_circles(hosts) when is_list(hosts) do
    circle_type =
      Utils.maybe_apply(Bonfire.Boundaries.Scaffold.Instance, :activity_pub_circle, [],
        fallback_return: nil
      )

    if circle_type do
      Utils.maybe_apply(
        Bonfire.Boundaries.Circles,
        :list_by_names,
        [hosts, circle_type],
        fallback_return: []
      )
      |> Enum.reduce(%{}, fn
        %{named: %{name: name}} = circle, acc when is_binary(name) -> Map.put(acc, name, circle)
        _, acc -> acc
      end)
    end || %{}
  end

  def instance_allowlisted?(host_or_uri, opts \\ [])

  def instance_allowlisted?(uri_or_id, opts) when is_binary(uri_or_id) do
    case get(uri_or_id) do
      {:ok, peer} ->
        instance_allowlisted?(peer, opts)

      _ ->
        # No Peer record — try via hostname circle directly (e.g. when added by hostname before actor fetch)
        hostname = Bonfire.Common.URIs.base_domain(uri_or_id) || uri_or_id

        with {:ok, circle} <-
               instance_circle_for(hostname, opts)
               |> debug("instance_circle by hostname for #{hostname}") do
          Bonfire.Boundaries.Allowlist.is_allowlisted?(circle, opts)
        else
          _ -> false
        end
    end
  end

  def instance_allowlisted?(%Peer{display_hostname: display_hostname}, opts) do
    with {:ok, circle} <-
           instance_circle_for(display_hostname, opts) |> debug("instance_circle for allowlist") do
      Bonfire.Boundaries.Allowlist.is_allowlisted?(circle, opts)
    else
      _ -> false
    end
  end

  # prefer an instance circle pre-resolved for the whole recipient set (`opts[:resolved]`, built by
  # `BoundariesMRF.filter/2`), falling back to a single `get_instance_circle/1` query when absent
  defp instance_circle_for(host, opts) do
    case ed(opts, :resolved, :allowlist_circles_by_hosts, host, nil) do
      nil -> get_instance_circle(host)
      circle -> {:ok, circle}
    end
  end

  def instance_allowlisted?(_, _opts), do: false

  def add_to_allowlist(host_or_peer, scope \\ :instance_wide)

  def add_to_allowlist(%Peer{display_hostname: display_hostname}, scope),
    do: add_to_allowlist(display_hostname, scope)

  def add_to_allowlist(host_or_uri, scope) when is_binary(host_or_uri) do
    with {:ok, circle} <- get_or_create_instance_circle(host_or_uri) do
      Bonfire.Boundaries.Allowlist.allow(circle, scope)
    end
  end

  def remove_from_allowlist(host_or_peer, scope \\ :instance_wide)

  def remove_from_allowlist(%Peer{display_hostname: display_hostname}, scope),
    do: remove_from_allowlist(display_hostname, scope)

  def remove_from_allowlist(host_or_uri, scope) when is_binary(host_or_uri) do
    with {:ok, circle} <- get_instance_circle(host_or_uri) do
      Bonfire.Boundaries.Allowlist.unallow(circle, scope)
    end
  end

  def list_allowlist(scope \\ :instance_wide),
    do: Bonfire.Boundaries.Allowlist.list(scope)

  def instance_blocked?(peered, block_type \\ :any, opts \\ [])

  def instance_blocked?(uri, block_type, opts) when is_binary(uri) do
    with {:ok, peer} <- get(uri) |> info("Instances.instance_blocked? get peer for #{uri}") do
      instance_blocked?(peer, block_type, opts)
    else
      other ->
        info(other, "Instances.instance_blocked? could not find peer for #{uri}")
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

  @doc """
  Query for instances involved in federated follows.
  `:incoming` = instances whose actors follow local actors.
  `:outgoing` = instances where local actors follow remote actors.
  """
  def federated_follows_query(direction) when direction in [:incoming, :outgoing] do
    {remote_side, local_side} =
      case direction do
        :incoming -> {:subject_id, :object_id}
        :outgoing -> {:object_id, :subject_id}
      end

    Bonfire.Social.Graph.Follows.query([], skip_boundary_check: true)
    |> join(:inner, [edge: edge], remote_peered in Bonfire.Data.ActivityPub.Peered,
      as: :remote_peered,
      on: field(edge, ^remote_side) == remote_peered.id
    )
    |> join(:inner, [remote_peered: rp], peer in Peer, as: :peer, on: peer.id == rp.peer_id)
    |> join(:left, [edge: edge], local_peered in Bonfire.Data.ActivityPub.Peered,
      as: :local_peered,
      on: field(edge, ^local_side) == local_peered.id
    )
    |> where([local_peered: lp], is_nil(lp.id))
  end

  @doc "Counts distinct instances whose actors follow local actors."
  def count_instances_following_local do
    federated_follows_query(:incoming)
    |> select([peer: p], count(p.id, :distinct))
    |> repo().one() || 0
  end

  @doc "Counts distinct instances where local actors follow remote actors."
  def count_instances_followed_by_local do
    federated_follows_query(:outgoing)
    |> select([peer: p], count(p.id, :distinct))
    |> repo().one() || 0
  end

  @doc "Lists distinct instances whose actors follow local actors."
  def list_instances_following_local do
    federated_follows_query(:incoming)
    |> select([peer: p], p)
    |> distinct([peer: p], p.id)
    |> repo().many()
  end

  @doc "Lists distinct instances where local actors follow remote actors."
  def list_instances_followed_by_local do
    federated_follows_query(:outgoing)
    |> select([peer: p], p)
    |> distinct([peer: p], p.id)
    |> repo().many()
  end

  @doc """
  Counts users/actors from each instance via `Peered` association.
  Returns a map of %{peer_id => count}.
  """
  def count_users_by_peer_ids(peer_ids) when is_list(peer_ids) and peer_ids != [] do
    from(p in Bonfire.Data.ActivityPub.Peered,
      where: p.peer_id in ^peer_ids,
      group_by: p.peer_id,
      select: {p.peer_id, count(p.id)}
    )
    |> repo().all()
    |> Map.new()
  end

  def count_users_by_peer_ids(_), do: %{}

  @doc """
  Finds the most recent activity timestamp for users from each instance.
  Returns a map of %{peer_id => datetime}.
  """
  def last_activity_by_peer_ids(peer_ids) when is_list(peer_ids) and peer_ids != [] do
    from(peered in Bonfire.Data.ActivityPub.Peered,
      join: created in Bonfire.Data.Social.Created,
      on: created.creator_id == peered.id,
      where: peered.peer_id in ^peer_ids,
      group_by: peered.peer_id,
      select: {peered.peer_id, max(created.id)}
    )
    |> repo().all()
    |> Map.new(fn {peer_id, ulid} ->
      # Extract timestamp from ULID (ULIDs encode timestamp in first 48 bits)
      {peer_id, Needle.ULID.timestamp(ulid)}
    end)
  end

  def last_activity_by_peer_ids(_), do: %{}
end
