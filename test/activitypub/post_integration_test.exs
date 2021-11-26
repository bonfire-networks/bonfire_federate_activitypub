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

    attrs = %{to_circles: [:guest], post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(user, attrs)

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)
    # IO.inspect(ap_activity)
    assert post.post_content.html_body =~ ap_activity.object.data["content"]
  end

  test "Reply publishing works" do
    attrs = %{
      post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}
    }

    user = fake_user!()
    ap_user = ActivityPub.Actor.get_by_local_id!(user.id)
    replier = fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs, "public")

    assert {:ok, original_activity} =
             Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    attrs_reply = %{
      post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"},
      reply_to_id: post.id
    }

    assert {:ok, post_reply} = Posts.publish(replier, attrs_reply, "public")

    assert {:ok, ap_activity} =
             Bonfire.Federate.ActivityPub.Publisher.publish("create", post_reply)

    assert ap_activity.object.data["inReplyTo"] == original_activity.object.data["id"]
    assert ap_user.ap_id in ap_activity.data["to"]
  end

  test "creates a Post for an incoming Note" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)
    context = "blabla"

    object = %{
      "content" => "content",
      "type" => "Note",
      "to" => [
        recipient_actor.ap_id,
        "https://www.w3.org/ns/activitystreams#Public"
      ]
    }

    to = [
      recipient_actor.ap_id,
      "https://www.w3.org/ns/activitystreams#Public"
    ]

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
    assert post.post_content.html_body =~ object["content"]

    assert Bonfire.Boundaries.Circles.circles[:guest] in Bonfire.Social.FeedActivities.feeds_for_activity(post.activity)
  end

  test "creates a a reply for an incoming note with a reply" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)
    context = "blabla"

    object = %{
      "content" => "content",
      "type" => "Note",
      "to" => [
        recipient_actor.ap_id,
        "https://www.w3.org/ns/activitystreams#Public"
      ]
    }

    to = [
      recipient_actor.ap_id,
      "https://www.w3.org/ns/activitystreams#Public"
    ]

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
    }

    {:ok, activity} = ActivityPub.create(params)

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)

    reply_object = %{
      "content" => "content",
      "type" => "Note",
      "inReplyTo" => activity.object.data["id"]
    }

    reply_params = %{
      actor: actor,
      context: context,
      object: reply_object,
      to: to
    }

    {:ok, reply_activity} = ActivityPub.create(reply_params)

    assert {:ok, reply} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(reply_activity)
    assert reply.replied.reply_to_id == post.id
  end

  test "does not set public circle for objects missing AP public URI" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)
    context = "blabla"

    object = %{
      "content" => "content",
      "type" => "Note",
      "to" => [
        recipient_actor.ap_id
      ]
    }

    to = [
      recipient_actor.ap_id
    ]

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

    assert Bonfire.Boundaries.Circles.circles[:guest] not in Bonfire.Social.FeedActivities.feeds_for_activity(post.activity)
  end
end
