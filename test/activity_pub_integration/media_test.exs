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

      assert {:ok, media} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload(emoji: [:extra_info])

      assert media.__struct__ == Bonfire.Data.Social.Like
      assert media.emoji.extra_info.summary == "🔥"

      # assert is_map(activity.json["object"])
      # assert activity.json["type"] == "EmojiReact"
    end
  end
end
