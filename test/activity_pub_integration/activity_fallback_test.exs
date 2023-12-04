defmodule Bonfire.Federate.ActivityPub.ActivityFallbackTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Social.Posts

  setup_all do
    data =
      "../fixtures/peertube-video.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))
    end)

    :ok
  end

  describe "" do
    test "peertube video object" do
      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == "Video"
      assert is_binary(activity.json["object"]["content"])
    end

    test "pleroma emoji react" do
      ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

      user = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      data =
        "../fixtures/pleroma-emojireact.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("object", ap_activity.data["object"])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert is_map(activity.json["object"])
      assert activity.json["type"] == "EmojiReact"
    end
  end
end
