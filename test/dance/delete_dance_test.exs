defmodule Bonfire.Federate.ActivityPub.Dance.DeleteTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase
  import Mneme
  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Users

  test "delete a post and gets deleted on a remote instance",
       context do
    local_follower = context[:local][:user]
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    followed_ap_id =
      context[:remote][:canonical_url]
      |> debug("followed_ap_id")

    Logger.metadata(action: info("init followed_on_local"))
    assert {:ok, followed_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(followed_ap_id)

    Logger.metadata(action: info("do the follow"))
    assert {:ok, follow} = Follows.follow(local_follower, followed_on_local)
    fid = ulid(follow)
    info(follow, "the follow")

    remote_followed = context[:remote][:user]
    post_attrs = %{post_content: %{html_body: "try federated post"}}

    remote_post =
      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: info("init follower_on_remote"))

        assert {:ok, follower_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

        assert ulid(follower_on_remote) != ulid(local_follower)
        assert ulid(remote_followed) != ulid(followed_on_local)

        Logger.metadata(action: info("check follow worked on remote"))

        Logger.metadata(action: info("make a post on remote"))

        {:ok, post} =
          Posts.publish(current_user: remote_followed, post_attrs: post_attrs, boundary: "public")

        post
      end)

    Logger.metadata(action: info("check that post was federated and is the follower's feed"))

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_follower)

    assert List.first(feed).activity.object.post_content.html_body =~
             post_attrs.post_content.html_body

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("delete the post"))
      {:ok, _} = Objects.delete(remote_post, current_user: remote_followed)
    end)

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_follower)
    auto_assert [] <- feed

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("delete the user"))
      {:ok, _} = Users.delete(remote_followed)
    end)

    auto_assert AdapterUtils.get_or_fetch_and_create_by_uri(followed_ap_id)
  end
end
