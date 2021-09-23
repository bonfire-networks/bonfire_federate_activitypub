defmodule Bonfire.Federate.ActivityPub.ActivityFallbackTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock

  alias Bonfire.Social.Posts

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end

  test "peertube video object" do
    data =
      "../fixtures/peertube-video.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    {:ok, data} = ActivityPubWeb.Transmogrifier.handle_incoming(data)

    assert {:ok, activity} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(data)
    assert activity.__struct__ == Bonfire.Data.Social.APActivity
    assert is_map(activity.json["object"])
    assert activity.json["object"]["type"] == "Video"
    assert is_binary(activity.json["object"]["content"])
  end

  test "pleroma emoji react" do
    ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")

    user = fake_user!()

    attrs = %{circles: [:guest], post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(user, attrs)

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    data =
      "../fixtures/pleroma-emojireact.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("object", ap_activity.data["object"])

    {:ok, data} = ActivityPubWeb.Transmogrifier.handle_incoming(data)

    assert {:ok, activity} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(data)
    assert is_map(activity.json["object"])
    assert activity.json["type"] == "EmojiReact"
  end
end
