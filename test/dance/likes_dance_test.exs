defmodule Bonfire.Federate.ActivityPub.Dance.LikesTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  @tag :test_instance
  test "like", context do
    # context |> info("context")

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
      post_content: %{html_body: "#{context[:remote][:username]} try federated @ mention"}
    }

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    TestInstanceRepo.apply(fn ->
      assert %{edges: feed} =
               Bonfire.Social.FeedActivities.feed(:notifications, current_user: remote_user)

      post1remote = List.first(feed).activity.object
      assert post1remote.post_content.html_body =~ "try federated @ mention"

      Logger.metadata(action: info("like it"))
      Bonfire.Social.Likes.like(remote_user, post1remote)
    end)

    Logger.metadata(action: info("check that like was federated and is in OP's feed"))

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_user)

    a_remote = List.first(feed).activity
    # assert a_remote.verb.verb == "Like"
    assert a_remote.verb_id == "11KES1ND1CATEAM11DAPPR0VA1"
    liked_post = a_remote.object
    assert liked_post.post_content.html_body =~ "try federated @ mention"
  end
end
