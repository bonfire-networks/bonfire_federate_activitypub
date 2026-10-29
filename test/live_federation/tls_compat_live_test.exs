defmodule Bonfire.Federate.ActivityPub.TlsCompatLiveTest do
  @moduledoc """
  A server whose TLS 1.3 handshake `:ssl` refuses by default: zotum.net runs h2o, which answers OTP's first key share with a HelloRetryRequest and no compatibility ChangeCipherSpec. Its posts are fetched all the same, and a reply from there shows under the post it answers.

  It reaches a real server, so it runs through the live recipe:

      just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/tls_compat_live_test.exs
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  # not `:test_instance`: it reaches real servers, so it runs through the live recipe only
  @moduletag :live_federation

  alias Bonfire.Data.Social.Replied
  alias ActivityPub.Federator.Fetcher

  @reply "https://zotum.net/item/b5f69b76-a5b8-492c-8ffb-2c0c89492e79"
  @parent "https://social.coop/users/django/statuses/117521731217740427"

  setup do
    ActivityPub.Instances.delete_host_cache("zotum.net", :tls_compat)
    :ok
  end

  test "a reply fetched from that server shows under the post it answers" do
    assert {:ok, parent} = Fetcher.fetch_object_from_id(@parent)
    assert {:ok, reply} = Fetcher.fetch_object_from_id(@reply)

    assert repo().get!(Replied, local_id(reply)).reply_to_id == local_id(parent)
  end

  # the AP object's id is its own; the local post is its `pointer_id`
  defp local_id(%ActivityPub.Object{data: %{"id" => ap_id}, pointer_id: pointer_id}) do
    refute is_nil(pointer_id), "#{ap_id} should be linked to a local object"
    pointer_id
  end

  test "Bonfire.Common.HTTP fetches from that server" do
    assert {:ok, %{status: 200, body: body}} =
             Bonfire.Common.HTTP.get(@reply, [{"Accept", "application/activity+json"}])

    assert body =~ "100% agreed"
  end
end
