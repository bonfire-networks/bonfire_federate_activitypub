defmodule Bonfire.Federate.ActivityPub.PollTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  # alias Bonfire.Posts

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      # %{url: "https://mocked.local/relation/27005"} ->

      # NOTE: already mocked in AP lib

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "Question is recorded as poll question if bonfire_poll extension is enabled, otherwise as APActivity" do
    data =
      "../fixtures/poll_attachment.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

    assert {:ok, activity} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
             |> repo().maybe_preload(choices: [:post_content])

    if Code.ensure_loaded?(Bonfire.Poll) do
      assert %Bonfire.Poll.Question{
               voting_format: "single",
               proposal_dates: nil,
               voting_dates: [_]
             } =
               activity
               |> debug("Question activity")

      e(activity, :choices, [])
      |> Enum.map(fn choice ->
        assert %Bonfire.Poll.Choice{} = choice

        assert choice.post_content.name in ["a", "b", "c", "d", "e", "f"]
      end)
      |> Enum.count() == 6
    else
      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_list(activity.json["oneOf"])
      assert activity.json["type"] == "Question"
      assert is_binary(activity.json["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)

      # Second fetch of the same data
      assert {:ok, activity2} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      # Should return the same activity, not create a duplicate
      assert activity.id == activity2.id
      assert activity.json["id"] == activity2.json["id"]
    end
  end
end
