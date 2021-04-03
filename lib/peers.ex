defmodule Bonfire.Federate.ActivityPub.Peers do

  def get_or_create(ap_base, domain) do
    case Bonfire.Repo.get_by(Bonfire.Data.ActivityPub.Peer, ap_url_base: ap_base) do
      nil ->
        with {:ok, peer} <- create(%{ap_url_base: ap_base, domain: domain}), do: peer

      peer ->
        peer
    end
  end

  def create(attrs) do
    #TODO
  end

end
