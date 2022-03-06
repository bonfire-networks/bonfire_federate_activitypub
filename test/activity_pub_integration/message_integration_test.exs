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

  test "can receive federated messages" do
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

    assert {:ok, _message} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end
end
