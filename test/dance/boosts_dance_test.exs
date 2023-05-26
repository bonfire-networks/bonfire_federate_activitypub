defmodule Bonfire.Federate.ActivityPub.Dance.BoostsTest do
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
  test "boost", context do
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
      post_content: %{html_body: "#{context[:remote][:username]} try federated boost"}
    }

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    TestInstanceRepo.apply(fn ->
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: remote_user)
      post1remote = List.first(feed).activity.object
      assert post1remote.post_content.html_body =~ "try federated boost"

      Logger.metadata(action: info("boost it"))
      Bonfire.Social.Boosts.boost(remote_user, post1remote)
    end)

    Logger.metadata(action: info("check that boost was federated and is in OP's feed"))

    assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: local_user)

    a_remote = List.first(feed).activity
    assert a_remote.verb.verb == "Boost"
    boosted_post = a_remote.object
    assert boosted_post.post_content.html_body =~ "try federated boost"
  end
end
