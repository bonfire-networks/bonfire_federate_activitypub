defmodule Bonfire.Federate.ActivityPub.Instances do
  @moduledoc """
  Federated instances
  Context for `Bonfire.Data.ActivityPub.Peer`
  """
  use Arrows
  import Bonfire.Federate.ActivityPub
  import Ecto.Query
  alias Bonfire.Data.ActivityPub.Peer

  def get(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    instance_url = "#{uri.scheme}://#{uri.host}"

    repo().single(peer_url_query(instance_url))
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

  def get_or_create(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    instance_url = "#{uri.scheme}://#{uri.host}"

    case do_get(instance_url) do
      {:ok, peer} ->
        {:ok, peer}

      _ ->
        create(%{ap_base_uri: instance_url, display_hostname: uri.host})
    end
  end

  def get_or_create(%{ap_id: canonical_uri}) do
    get_or_create(canonical_uri)
  end

  def is_blocked?(uri) when is_binary(uri) do
    get_or_create(uri)
    ~> is_blocked?()
  end

  def is_blocked?(%Peer{} = peer) do
    Bonfire.Boundaries.is_blocked?(peer)
  end

end
