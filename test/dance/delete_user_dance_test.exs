defmodule Bonfire.Federate.ActivityPub.Dance.DeleteUserTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  import Mneme
  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias ActivityPub.Tests.ObanHelpers

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Users

  # TODO: check that user's posts also get auto-deleted
  # FIXME
  test "delete a user and it gets deleted on follower's on a remote instance",
       context do
    local_user = context[:local][:user]
    local_ap_id = Bonfire.Me.Characters.character_url(local_user)
    info(local_ap_id, "local_ap_id")

    remote_ap_id =
      context[:remote][:canonical_url]
      |> debug("remote_ap_id")

    Logger.metadata(action: info("init remote_on_local"))
    assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    Logger.metadata(action: info("do the follow"))
    assert {:ok, follow} = Follows.follow(local_user, remote_on_local)
    fid = uid(follow)
    info(follow, "the follow")

    remote_user = context[:remote][:user]
    post_attrs = %{post_content: %{html_body: "try user federated post"}}

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init local_on_remote"))

      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      assert uid(local_on_remote) != uid(local_user)
      assert uid(remote_user) != uid(remote_on_local)

      Logger.metadata(action: info("check follow worked on remote"))
      assert Follows.following?(local_on_remote, remote_user)

      Logger.metadata(action: info("delete the user on remote"))

      assert {:ok, _post} =
               Posts.publish(
                 current_user: remote_user,
                 post_attrs: post_attrs,
                 boundary: "public"
               )
    end)

    Logger.metadata(action: info("check that post was federated and is the follower's feed"))

    assert post_id =
             Bonfire.Social.FeedLoader.feed_contains?(
               :my,
               post_attrs.post_content.html_body,
               current_user: local_user
             )

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("delete user on remote"))
      {:ok, _} = Users.enqueue_delete(remote_user)
    end)

    Logger.metadata(action: info("run queued deletion on local"))
    ObanHelpers.perform_all()

    Logger.metadata(action: info("check user deletion was federated"))

    assert {:error, :not_found} = Users.by_id(Enums.id(remote_on_local))
    assert {:error, :not_found} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    Logger.metadata(action: info("check user's posts were deleted too"))

    refute Bonfire.Social.FeedLoader.feed_contains?(:my, post_id, current_user: local_user)
  end
end
