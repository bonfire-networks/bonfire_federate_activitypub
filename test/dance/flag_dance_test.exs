defmodule Bonfire.Federate.ActivityPub.Dance.FlagDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts

  test "cross-instance flagging", context do
    # context |> info("context")

    local_admin = fake_admin!()
    local_user = context[:local][:user]
    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    remote_user = context[:remote][:user]

    post1_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} post to try federated flagging"}
    }

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    post1_url = Bonfire.Common.URIs.canonical_url(post1)

    TestInstanceRepo.apply(fn ->
      assert {:ok, post_on_remote} =
               AdapterUtils.get_by_url_ap_id_or_username(post1_url)

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:remote, "post to try federated flagging",
                 current_user: remote_user
               )

      post1remote = activity.object

      Logger.metadata(action: info("flag it"))

      Bonfire.Social.Flags.flag(remote_user, post1remote)
      |> debug("the flaggg")
    end)

    Logger.metadata(action: info("make sure the incoming flag in queue was processed"))
    Oban.drain_queue(queue: :federator_incoming)

    Logger.metadata(action: info("check flag was federated"))

    flags =
      Bonfire.Social.Flags.list(
        scope: :instance,
        current_user: local_admin
      )

    assert flags != []

    # FIXME
    assert Bonfire.Social.FeedLoader.feed_contains?(
             flags,
             "post to try federated flagging",
             current_user: local_admin
           )

    Logger.metadata(action: info("check flag was federated and is in admin's notifications"))

    assert %{verb_id: verb_id, object: _object} =
             activity =
             Bonfire.Social.FeedLoader.feed_contains?(
               :notifications,
               "post to try federated flagging",
               current_user: local_admin
             )

    assert verb_id == "71AGSPAM0RVNACCEPTAB1E1TEM"
  end
end
