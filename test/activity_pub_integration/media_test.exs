defmodule Bonfire.Federate.ActivityPub.MediaTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts
  use Bonfire.Common.Repo

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

  describe "supports incoming" do
    test "peertube video object" do
      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://peertube.linuxrocks.local/static/web-videos/39a9890f-a115-40c9-a8a4-c4d2d286ef27-1440.mp4"

      assert media.media_type == "video/mp4"

      assert {:ok, _} = Bonfire.Social.Objects.read(media.id)
    end

    test "non-public peertube video object" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("to", recipient_actor)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://peertube.linuxrocks.local/static/web-videos/39a9890f-a115-40c9-a8a4-c4d2d286ef27-1440.mp4"

      assert media.media_type == "video/mp4"

      assert {:error, _} = Bonfire.Social.Objects.read(media.id)
      assert {:ok, _} = Bonfire.Social.Objects.read(media.id, current_user: recipient)
    end
  end
end
