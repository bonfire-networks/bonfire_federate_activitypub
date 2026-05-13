defmodule Bonfire.Federate.ActivityPub.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  def handle_event("refetch_profile:" <> id, _params, socket) do
    with {:ok, actor} <- ActivityPub.Actor.get_cached_or_fetch(id),
         ap_id when is_binary(ap_id) <- e(actor, :ap_id, nil),
         false <- String.starts_with?(ap_id, AdapterUtils.ap_base_url()) do
      ActivityPub.Federator.Fetcher.enqueue_fetch(ap_id, %{"fresh" => true})
    end

    {:noreply, socket}
  end
end
