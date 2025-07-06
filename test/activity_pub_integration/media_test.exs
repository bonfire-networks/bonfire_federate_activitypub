defmodule Bonfire.Federate.ActivityPub.MediaTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts
  use Bonfire.Common.Repo

  setup_all do
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

    test "funkwhale audio object" do
      data =
        "../fixtures/funkwhale_create_audio.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://funkwhale.local/api/v1/listen/3901e5d8-0445-49d5-9711-e096cf32e515/?upload=42342395-0208-4fee-a38d-259a6dae0871&download=false"

      assert media.media_type == "audio/ogg"

      assert {:ok, _} = Bonfire.Social.Objects.read(media.id)
    end
  end
end
