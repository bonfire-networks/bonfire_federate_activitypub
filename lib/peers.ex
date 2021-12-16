defmodule Bonfire.Federate.ActivityPub.Peers do
  alias Bonfire.Data.ActivityPub.Peer
  import Bonfire.Federate.ActivityPub
  import Ecto.Query

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
    ap_base_url = uri.scheme <> "://" <> uri.host

    case repo().single(peer_url_query(ap_base_url)) do
      {:ok, peer} ->
        {:ok, peer}

      {:error, _} ->
        create(%{ap_base_uri: ap_base_url, display_hostname: uri.host})
    end
  end


  def get_or_create(%{data: %{"id" => uri}}) do
    get_or_create(uri)
  end

end
