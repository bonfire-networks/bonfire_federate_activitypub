defmodule Bonfire.Federate.ActivityPub.EventTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "" do
    test "event is recorded as APActivity" do
      type = "Event"

      data =
        "../fixtures/mobilizon.org-event.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      # |> Map.put("type", type)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      # NOTE: temp until an extension implements events
      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == type
      assert is_binary(activity.json["object"]["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)

      feed = Bonfire.Social.FeedLoader.feed(:explore)
      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity)

      feed = Bonfire.Social.FeedLoader.feed(:explore, %{object_types: ["Event"]}, [])
      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity)
    end

    test "non-public event is recorded as private APActivity" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      type = "Event"

      data =
        "../fixtures/mobilizon.org-event.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        # |> Map.put("type", type)
        |> Map.put("to", recipient_actor)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)
      # |> debug("handled")

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == type
      assert is_binary(activity.json["object"]["content"])

      assert {:error, _} = Bonfire.Social.Objects.read(activity.id)
      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id, current_user: recipient)
    end
  end
end
