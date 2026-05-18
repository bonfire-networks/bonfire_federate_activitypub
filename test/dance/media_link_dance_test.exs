defmodule Bonfire.Federate.ActivityPub.Dance.MediaLinkTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @tag :test_instance
  test "a link/article Media (as created by comments_embed) federates as a link, not an audio file",
       context do
    local_user = context[:local][:user]

    Logger.metadata(action: "create local link Media (comments_embed flow)")

    url = "https://example.com/some/article"

    # This mirrors what `comments_embed` does once Unfurl has run:
    # `Bonfire.Files.Media.maybe_save/4` inserts a Media with a non-media
    # `media_type` (here "link") and then publishes/federates it. We insert +
    # publish directly to keep the test network-free and deterministic.
    {:ok, media} =
      Bonfire.Files.Media.insert(
        local_user,
        url,
        %{media_type: "link", size: 0},
        %{
          url: url,
          media_type: "link",
          metadata: %{"label" => "Some Article Title"}
        }
      )

    assert {:ok, _published} =
             Bonfire.Files.Media.publish(local_user, media, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(media)
      |> info("canonical_url")

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch the federated link Media on the remote instance")

      assert {:ok, remote_object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload([:post_content, :media])

      # The regression: a plain link must never be hijacked into an
      # `audio/mp3` Media by the Audio receive clause's guard.
      refute match?(%Bonfire.Files.Media{media_type: "audio/mp3"}, remote_object)

      # A Page without image/audio/video is saved as a Post (link preview).
      assert remote_object.__struct__ == Bonfire.Data.Social.Post
    end)
  end
end
