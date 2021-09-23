defmodule Bonfire.Federate.ActivityPub.ActivityFallbackTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end

  test "peertube video object" do
    data =
      # FIXME: This only works when forked
      File.read!("forks/bonfire_federate_activitypub/test/fixtures/peertube-video.json")
      |> Jason.decode!()

    {:ok, data} = ActivityPubWeb.Transmogrifier.handle_incoming(data)

    assert {:ok, activity} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(data)
    assert activity.__struct__ == Bonfire.Data.Social.APActivity
    assert is_map(activity.json["object"])
    assert activity.json["object"]["type"] == "Video"
    assert is_binary(activity.json["object"]["content"])
  end
end
