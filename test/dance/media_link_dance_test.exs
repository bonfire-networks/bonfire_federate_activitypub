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
      Bonfire.Common.URIs.canonical_url(media, preload_if_needed: true)
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

  @tag :test_instance
  test "a published link Media carries its title, description and cover image to the other instance",
       context do
    local_user = context[:local][:user]

    url = "https://example.com/described/article"

    {:ok, media} =
      Bonfire.Files.Media.insert(
        local_user,
        url,
        %{media_type: "link", size: 0},
        %{
          url: url,
          media_type: "link",
          metadata: %{
            "label" => "A Described Article",
            "description" => "What the article is about",
            "facebook" => %{"image" => "https://example.com/described-og.jpg"}
          }
        }
      )

    assert {:ok, _} = Bonfire.Files.Media.publish(local_user, media, boundary: "public")

    canonical_url = Bonfire.Common.URIs.canonical_url(media, preload_if_needed: true)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch the published link Media on the remote instance")

      assert {:ok, remote_object} = AdapterUtils.get_by_url_ap_id_or_username(canonical_url)

      # A `Page` carrying a cover image is Lemmy's link-post shape, and Bonfire receives one as
      # Media rather than a Post — see the payload table in `threadiverse_interop_test.exs`.
      remote_media = e(remote_object, :object, nil) || remote_object
      assert %Bonfire.Files.Media{id: remote_media_id} = remote_media

      # read it back the way anything rendering it would: `create_and_publish/6` builds the
      # metadata with an atom `:json_ld` key, which is only the string key the readers look for
      # once it has been through the database
      assert {:ok, remote_media} = Bonfire.Files.Media.one(id: remote_media_id)

      # the remote instance should not have to go and fetch example.com to show a usable card
      assert Bonfire.Files.Media.media_label(remote_media) == "A Described Article"

      assert Bonfire.Files.Media.description(remote_media) == "What the article is about"

      assert Bonfire.Files.Media.preview_image_url(remote_media) ==
               "https://example.com/described-og.jpg"
    end)
  end

  @tag :test_instance
  test "a post's image attachment keeps its alt text on the other instance", context do
    local_user = context[:local][:user]

    alt = "A sunset over the sea #{System.unique_integer([:positive])}"

    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        local_user,
        Bonfire.Files.Simulation.image_file(),
        %{metadata: %{"alt" => alt, "label" => "beach.png"}}
      )

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: local_user,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "look at this"},
          uploaded_media: [media]
        }
      )

    canonical_url = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch the post with an image attachment on the remote instance")

      assert {:ok, remote_post} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload([:post_content, :media])

      assert [remote_media] = remote_post.media

      assert Bonfire.Files.Media.media_alt(remote_media, false) == alt,
             "alt text is the whole point of `name` on an AS2 attachment, so it has to survive the round trip"
    end)
  end

  @tag :test_instance
  test "a post's link attachment keeps its title, description and cover image on the other instance",
       context do
    local_user = context[:local][:user]

    url = "https://example.com/attached/article-#{System.unique_integer([:positive])}"

    {:ok, media} =
      Bonfire.Files.save_url_as_media(local_user, url, %{
        media_type: "link",
        metadata: %{
          "label" => "An Attached Article",
          "description" => "What that one is about",
          "facebook" => %{"image" => "https://example.com/attached-og.jpg"}
        }
      })

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: local_user,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "worth a read"},
          uploaded_media: [media]
        }
      )

    canonical_url = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch the post with a link attachment on the remote instance")

      assert {:ok, remote_post} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload([:post_content, :media])

      assert [remote_media] = Enum.filter(remote_post.media, &(&1.path == url))

      assert Bonfire.Files.Media.media_label(remote_media) == "An Attached Article"
      assert Bonfire.Files.Media.description(remote_media) == "What that one is about"

      assert Bonfire.Files.Media.preview_image_url(remote_media) ==
               "https://example.com/attached-og.jpg"
    end)
  end
end
