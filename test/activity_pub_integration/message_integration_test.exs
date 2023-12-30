defmodule Bonfire.Federate.ActivityPub.MessageIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Messages

  import Tesla.Mock

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

  describe "" do
    test "messages get queued to federate" do
      me = fake_user!()
      messaged = fake_user!()

      msg = "hey you have an epic text message"
      attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}

      assert {:ok, message} = Messages.send(me, attrs)

      ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(message)
      assert %{__struct__: ActivityPub.Object} = ap_activity

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "can federate message" do
      me = fake_user!()
      messaged = fake_user!()
      msg = "hey you have an epic text message"
      attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}
      assert {:ok, message} = Messages.send(me, attrs)

      {:ok, activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(message)

      assert activity.object.data["content"] =~ msg
    end

    test "can receive federated ChatMessage" do
      me = fake_user!()
      {:ok, local_actor} = ActivityPub.Actor.get_cached(pointer: me.id)
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      context = "blabla"

      object = %{
        "id" => @remote_instance <> "/pub/" <> Pointers.ULID.autogenerate(),
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

      assert {:ok, %Bonfire.Data.Social.Message{} = message} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
    end

    test "creates a Message for an incoming private Note with @ mention" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      params =
        remote_activity_json_with_mentions(actor, recipient_actor)
        |> info("json!")

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, %Bonfire.Data.Social.Message{} = message} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(:post_content)

      assert message.post_content.html_body =~ params.object["content"]

      assert %{edges: feed} = Messages.list(recipient)
      assert List.first(feed).id == message.id

      feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)

      refute =
        Bonfire.Social.FeedActivities.feed_contains?(feed_id, message, current_user: recipient)
    end

    test "rejects a Message for an incoming private Note for a user with federation disabled" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      recipient = fake_user!()

      recipient =
        Bonfire.Federate.ActivityPub.disable(recipient)
        ~> current_user()

      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      params =
        remote_activity_json_with_mentions(actor, recipient_actor)
        |> info("json!")

      {:error, _} = ActivityPub.create(params)
    end
  end
end
