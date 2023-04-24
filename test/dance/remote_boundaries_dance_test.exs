defmodule Bonfire.Federate.ActivityPub.Dance.RemoteBoundariesDanceTest do
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
  alias Bonfire.Boundaries.{Circles, Acls, Grants}

  test "custom with circle containing remote users permitted", context do
    post1_attrs = %{
      post_content: %{html_body: "try out federated post with circle containing remote users"}
    }

    alice_local = context[:local][:user]
    bob_remote = context[:remote][:user]

    alice_local_ap_id = context[:local][:canonical_url]
    bob_remote_ap_id = context[:local][:canonical_url]

    {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

    # create a circle with bob_remote in it
    {:ok, circle} = Circles.create(alice_local, %{named: %{name: "family"}})
    {:ok, _} = Circles.add_to_circles(bob_remote_user_on_local.id, circle)

    # on remote instance, bob_remote follows alice_local
    TestInstanceRepo.apply(fn ->
      {:ok, local_from_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_local_ap_id)

      Follows.follow(bob_remote, local_from_remote)
      |> debug("ffffoo")

      assert Follows.following?(bob_remote, local_from_remote)
    end)

    assert Follows.following?(bob_remote_user_on_local, alice_local)

    # on local instance, alice_local create a post with circle
    {:ok, post1} =
      Posts.publish(
        current_user: alice_local,
        post_attrs: post1_attrs,
        boundary: "public",
        to_circles: %{circle.id => "interact"}
      )

    # on remote instance, bob_remote should see the post
    TestInstanceRepo.apply(fn ->
      assert %{edges: [feed_entry | _]} =
               Bonfire.Social.FeedActivities.feed(:my, current_user: bob_remote)
               |> debug("bob feed")
    end)
  end
end
