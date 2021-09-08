defmodule Bonfire.Federate.ActivityPub.MessageIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Messages

  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end

  test "can federate message" do
    me = fake_user!()
    messaged = fake_user!()
    msg = "hey you have an epic text message"
    attrs = %{circles: [messaged.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(me, attrs)

    {:ok, activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", message)

    assert activity.object.data["content"] == msg
  end

  test "can receive federated messages" do
    me = fake_user!()
    {:ok, local_actor} = ActivityPub.Actor.get_by_local_id(me.id)
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    context = "blabla"
    object = %{"content" => "content", "type" => "ChatMessage"}
    to = [local_actor.ap_id]

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
    }

    {:ok, activity} = ActivityPub.create(params)

    assert {:ok, _message} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end
end
