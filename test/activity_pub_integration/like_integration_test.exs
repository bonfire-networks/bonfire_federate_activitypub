defmodule Bonfire.Federate.ActivityPub.LikeIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Likes

  import Tesla.Mock

  setup_all do
    mock(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))
    end)

    :ok
  end

  test "likes get queued to federate" do
    me = fake_user!()
    post_creator = fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: post_creator,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(me, post)

    ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(like)
    assert %{__struct__: ActivityPub.Object} = ap_activity

    Oban.Testing.assert_enqueued(repo(),
      worker: ActivityPub.Federator.Workers.PublisherWorker,
      args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
    )
  end

  test "like publishing works" do
    user = fake_user!()
    liker = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    {:ok, like} = Likes.like(liker, post)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(like)
  end

  test "like receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://mocked.local/users/karen")

    {:ok, ap_like} = ActivityPub.like(%{actor: actor, object: ap_activity.object})

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_like)
  end

  test "unlike receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://mocked.local/users/karen")

    {:ok, ap_like} = ActivityPub.like(%{actor: actor, object: ap_activity.object})

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_like)

    {:ok, ap_unlike} = ActivityPub.unlike(%{actor: actor, object: ap_activity.object})

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_unlike)
  end
end
