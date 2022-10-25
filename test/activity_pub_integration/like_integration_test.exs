defmodule Bonfire.Federate.ActivityPub.LikeIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Likes

  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))
    end)

    :ok
  end

  test "like publishing works" do
    user = fake_user!()
    liker = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, like} = Likes.like(liker, post)

    assert {:ok, _, _} =
             Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{
               args: %{"op" => "create", "context_id" => like.id}
             })
  end

  test "like receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://mocked.local/users/karen")

    {:ok, ap_like, _} = ActivityPub.like(actor, ap_activity.object)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_like)
  end

  test "unlike receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://mocked.local/users/karen")

    {:ok, ap_like, _} = ActivityPub.like(actor, ap_activity.object)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_like)

    {:ok, ap_unlike, _, _} = ActivityPub.unlike(actor, ap_activity.object)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_unlike)
  end
end
