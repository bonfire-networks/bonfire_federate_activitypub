defmodule Bonfire.Federate.ActivityPub.Dance.FlagDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Flags

  test "cross-instance flagging (with forward: true)", context do
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

      Bonfire.Social.Flags.flag(remote_user, post1remote,
        forward: true,
        comment: "federated flag"
      )
      |> debug("the flaggg")

      assert true == Flags.flagged_object?(post1remote)
    end)

    Logger.metadata(action: info("make sure the incoming flag in queue was processed"))
    Oban.drain_queue(queue: :federator_incoming)

    Logger.metadata(action: info("check flag was federated"))

    assert true == Flags.flagged_object?(post1)

    # %{edges: flags} =
    #   Bonfire.Social.Flags.list(
    #     scope: :instance,
    #     current_user: local_admin
    #   )

    # assert flags != []

    assert flag_edge =
             Bonfire.Social.FeedLoader.feed_contains?(
               :flagged_content,
               #  flags,
               "post to try federated flagging",
               current_user: local_admin
             )
             |> repo().maybe_preload(:named)

    Logger.metadata(action: info("check flag comment was federated"))

    # # Get the flag with preloaded named association to check the comment
    # %{edges: [flag_edge | _]} = 
    #   Bonfire.Social.Flags.list_preloaded(
    #     scope: :instance,
    #     current_user: local_admin
    #   )

    assert flag_edge.named.name == "federated flag",
           "Flag comment should be federated with the flag"

    Logger.metadata(action: info("check flag was federated and is in admin's notifications"))

    assert %{verb_id: verb_id, object: object} =
             activity =
             Bonfire.Social.FeedLoader.feed_contains?(
               :notifications,
               "post to try federated flagging",
               current_user: local_admin
             )
             |> repo().maybe_preload(:named)

    assert verb_id == "71AGSPAM0RVNACCEPTAB1E1TEM"

    # Verify the comment is also present in the notification activity
    assert activity.named.name == "federated flag",
           "Flag comment should be present in admin's notification"
  end

  test "flag with forward: false (default) does not federate to remote instance", context do
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]

    post_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} post - testing no forward"}
    }

    remote_post_url =
      TestInstanceRepo.apply(fn ->
        {:ok, post1} =
          Posts.publish(current_user: remote_user, post_attrs: post_attrs, boundary: "public")

        Bonfire.Common.URIs.canonical_url(post1)
      end)

    Logger.metadata(action: info("fetch remote post to local instance"))
    assert {:ok, post_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_post_url)

    Logger.metadata(action: info("flag it locally without forward (default behavior)"))

    {:ok, _flag} =
      Bonfire.Social.Flags.flag(local_user, post_on_local, comment: "local flag only")

    Logger.metadata(action: info("drain federation queues"))
    Oban.drain_queue(queue: :federator_outgoing)
    Oban.drain_queue(queue: :ap_incoming)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("verify flag was NOT received on remote instance"))

      remote_admin = fake_admin!()

      notifications =
        Bonfire.Social.FeedActivities.feed(:notifications, current_user: remote_admin)

      refute Bonfire.Social.FeedLoader.feed_contains?(
               notifications,
               "testing no forward",
               current_user: remote_admin
             ),
             "Flag should not forward by default (safe by default principle)"
    end)
  end
end
