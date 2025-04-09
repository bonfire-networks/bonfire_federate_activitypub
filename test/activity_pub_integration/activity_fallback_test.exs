defmodule Bonfire.Federate.ActivityPub.ActivityFallbackTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts

  setup_all do
    data =
      "../fixtures/peertube-video.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "" do
    test "object with Custom Type is recorded as APActivity" do
      type = "CustomType"

      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("type", type)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_map(activity.json["object"])
      assert activity.json["object"]["type"] == type
      assert is_binary(activity.json["object"]["content"])
    end
  end
end
