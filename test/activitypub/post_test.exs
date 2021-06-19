defmodule Bonfire.Federate.ActivityPub.PostIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Posts

  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end


  test "Post publishing works" do
    user = fake_user!()

    attrs = %{circles: [:guest], post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(user, attrs)


    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)
    # IO.inspect(ap_activity)
    assert ap_activity.object.data["content"] == attrs.post_content.html_body

  end


  test "creates a Post for an incoming Note" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    context = "blabla"
    object = %{"content" => "content", "type" => "Note"}
    to = ["https://testing.kawen.dance/users/karen"]

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
    }

    {:ok, activity} = ActivityPub.create(params)

    assert actor.data["id"] == activity.data["actor"]
    assert object["content"] == activity.object.data["content"]

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)

    # IO.inspect(post)
    assert object["content"] == post.post_content.html_body

  end




end
