defmodule Bonfire.Federate.ActivityPub.MessageIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Messages

  import Tesla.Mock

  @remote_instance "https://kawen.space"
  @remote_actor @remote_instance<>"/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

  test "can federate message" do
    me = fake_user!()
    messaged = fake_user!()
    msg = "hey you have an epic text message"
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(me, attrs)

    {:ok, activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", message)

    assert activity.object.data["content"] =~ msg
  end

  test "can receive federated ChatMessage" do
    me = fake_user!()
    {:ok, local_actor} = ActivityPub.Actor.get_by_local_id(me.id)
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    context = "blabla"
    object = %{
      "id" => @remote_instance<>"/pub/"<>Pointers.ULID.autogenerate(),
      "content" => "content",
      "type" => "ChatMessage"
    }
    to = [local_actor.ap_id]

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
    }

    {:ok, activity} = ActivityPub.create(params)

    assert {:ok, %Bonfire.Data.Social.Message{} = message} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end

  test "creates a Message for an incoming private Note with @ mention" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)

    params = remote_PM_json(actor, recipient_actor)
    |> info("json!")

    {:ok, activity} = ActivityPub.create(params)

    assert actor.data["id"] == activity.data["actor"]
    assert params.object["content"] == activity.object.data["content"]

    assert {:ok, %Bonfire.Data.Social.Message{} = message} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
    assert message.post_content.html_body =~ params.object["content"]

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end
end
