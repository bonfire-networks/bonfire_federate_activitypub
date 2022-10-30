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

  def get(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    instance_url = "#{uri.scheme}://#{uri.host}"

    do_get(instance_url)
  end

  defp do_get(instance_url) do
    repo().single(peer_url_query(instance_url))
  end

  defp create(attrs) do
    repo().insert(Peer.changeset(%Peer{}, attrs))
  end

  defp peer_url_query(url) do
    from(p in Peer,
      where: p.ap_base_uri == ^url
    )
  end

  def get_or_create("https://www.w3.org/ns/activitystreams#Public"), do: nil
  def get_or_create(%{ap_id: canonical_uri}), do: get_or_create(canonical_uri)
  def get_or_create(%{"id" => canonical_uri}), do: get_or_create(canonical_uri)

  def get_or_create(%{data: %{"id" => canonical_uri}}),
    do: get_or_create(canonical_uri)

  def get_or_create(canonical_uri) when is_binary(canonical_uri) do
    local_instance = Bonfire.Common.URIs.base_url()
    # only create Peer for remote instances
    if !String.starts_with?(canonical_uri, local_instance) do
      do_get_or_create(canonical_uri)
    else
      info(canonical_uri)
      info(local_instance)
      error("Local actor treated as remote")
    end
  end

  defp do_get_or_create(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    instance_url = "#{uri.scheme}://#{uri.host}"

    case do_get(instance_url) do
      {:ok, peer} ->
        {:ok, peer}

      none ->
        debug(instance_url, "instance unknown, create it now")
        create(%{ap_base_uri: instance_url, display_hostname: uri.host})
    end
  end

  def is_blocked?(peered, block_type \\ :any, opts \\ [])

  def is_blocked?(uri, block_type, opts) when is_binary(uri) do
    get_or_create(uri)
    ~> is_blocked?(block_type, opts)
  end

  def is_blocked?(%Peer{} = peer, block_type, opts) do
    Bonfire.Boundaries.Blocks.is_blocked?(peer, block_type, opts)
  end
end