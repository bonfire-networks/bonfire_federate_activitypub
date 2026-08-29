defmodule Bonfire.Federate.ActivityPub.MediaMetadataTest do
  @moduledoc """
  Media carries two distinct author-provided strings: an `alt` (the accessibility description of what the image shows) and a `label` (a caption/title). AS2 attachments only have one slot for that, `name`, which Mastodon & co. treat as the alt text, so `alt` is what has to go on the wire.

  Link-preview Media (a `Media` whose `path` is a remote URL, created by `Bonfire.Files.Acts.URLPreviews`) carries a title and description too, and those have to reach the other instance rather than being dropped from the outgoing object.
  """
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock

  alias Bonfire.Posts
  alias Bonfire.Files
  alias Bonfire.Files.Media
  alias Bonfire.Federate.ActivityPub.Outgoing

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    Process.put(:federating, true)

    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  defp post_with(user, media, body \\ "look at this") do
    Posts.publish(
      current_user: user,
      boundary: "public",
      post_attrs: %{
        post_content: %{html_body: body},
        uploaded_media: [media]
      }
    )
  end

  defp published_object(post) do
    assert {:ok, _} = Outgoing.push_now!(post)
    assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
    data
  end

  # what `Bonfire.Files.Acts.URLPreviews` ends up with for a link in a post's body
  defp link_media(user, url) do
    Files.save_url_as_media(user, url, %{
      media_type: "link",
      metadata: %{
        "label" => "The Article Title",
        "description" => "What the article is about",
        "facebook" => %{"image" => "https://example.com/og.jpg"}
      }
    })
  end

  describe "alt text federates outgoing" do
    test "an image attachment's `name` is the author-provided alt text" do
      user = fake_user!()

      assert {:ok, media} =
               Files.upload(
                 Bonfire.Files.ImageUploader,
                 user,
                 Bonfire.Files.Simulation.image_file(),
                 %{metadata: %{"alt" => "A sunset over the sea", "label" => "beach.png"}}
               )

      assert {:ok, post} = post_with(user, media)

      data = published_object(post)

      assert [attachment] = List.wrap(data["attachment"])

      assert attachment["name"] == "A sunset over the sea",
             "AS2 `name` on an attachment is the alt text, not the caption/filename"
    end

    test "falls back to the label when the author gave no alt text" do
      user = fake_user!()

      assert {:ok, media} =
               Files.upload(
                 Bonfire.Files.ImageUploader,
                 user,
                 Bonfire.Files.Simulation.image_file(),
                 %{metadata: %{"label" => "A caption"}}
               )

      assert {:ok, post} = post_with(user, media)

      data = published_object(post)

      assert [attachment] = List.wrap(data["attachment"])
      assert attachment["name"] == "A caption"
    end

    test "the primary image's alt text federates too" do
      user = fake_user!()

      assert {:ok, media} =
               Files.upload(
                 Bonfire.Files.ImageUploader,
                 user,
                 Bonfire.Files.Simulation.image_file(),
                 %{metadata: %{"alt" => "A chart of rising costs", "primary_image" => true}}
               )

      assert {:ok, post} = post_with(user, media)

      data = published_object(post)

      assert data["image"]["name"] == "A chart of rising costs"
    end
  end

  describe "alt text federates incoming" do
    test "an image attachment's `name` is stored as the media's alt text" do
      alt = "A cat asleep on a keyboard"

      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("attachment", [
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://example.com/cat.jpg",
            "name" => alt
          }
        ])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert [media] = post.media

      assert Media.media_alt(media, false) == alt,
             "a remote attachment's `name` is its alt text, so it must survive as one"
    end

    test "an image attachment is still an image once its `url` Link is folded in" do
      # AS2 wraps an attachment's `url` in a `Link` object, and folding that into the attachment used to let the Link's `type` stand in for the attachment's own `Document`/`Image`, which both routed the file to the document uploader and made its `name` read as a link title rather than as alt text
      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("attachment", [
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => [
              %{
                "type" => "Link",
                "mediaType" => "image/png",
                "href" => "https://example.com/wrapped.png"
              }
            ],
            "name" => "A diagram of the pipeline"
          }
        ])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert [media] = post.media
      assert media.media_type == "image/png"
      assert Media.media_alt(media, false) == "A diagram of the pipeline"
    end
  end

  describe "link previews federate as an attachment" do
    test "a link-preview Media attached to a post federates with its title and description" do
      user = fake_user!()
      url = "https://example.com/some/article"

      assert {:ok, media} = link_media(user, url)

      assert {:ok, post} = post_with(user, media, "worth a read: #{url}")

      data = published_object(post)

      assert [attachment] =
               List.wrap(data["attachment"])
               |> Enum.filter(&(&1["href"] == url or &1["url"] == url))

      assert attachment["name"] == "The Article Title"
      assert attachment["summary"] == "What the article is about"

      assert attachment["image"]["url"] == "https://example.com/og.jpg",
             "the cover image we resolved for the link should not have to be re-fetched remotely"
    end

    test "an incoming Link attachment keeps its title, description and cover image" do
      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("attachment", [
          %{
            "type" => "Link",
            "mediaType" => "link",
            "href" => "https://example.com/another/article",
            "name" => "Another Article Title",
            "summary" => "What that one is about",
            "image" => %{"type" => "Image", "url" => "https://example.com/another-og.jpg"}
          }
        ])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert [media] = post.media

      assert Media.media_label(media) == "Another Article Title"
      assert Media.description(media) == "What that one is about"
      assert Media.preview_image_url(media) == "https://example.com/another-og.jpg"
    end

    # the control for the test below: without it, the dedup test would pass just as well if the body link were never noticed at all, proving nothing
    test "a link in the body with no attachment does become its own Media" do
      url = "https://example.com/only-in-the-body/article"

      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("content", "<p>worth a read: <a href=\"#{url}\">#{url}</a></p>")
        |> Map.drop(["attachment"])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert [_] = Enum.filter(post.media, &(&1.path == url)),
             "URLPreviews should pick a link out of an incoming post's body"
    end

    test "a link that arrives with its metadata is not fetched again" do
      # the same link is in the body AND in the attachment; `Bonfire.Files.Acts.URLPreviews` runs
      # over the body when the incoming post is published, and must reuse the Media the attachment
      # already created rather than unfurling the page a second time
      url = "https://example.com/already/described"

      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("content", "<p>worth a read: <a href=\"#{url}\">#{url}</a></p>")
        |> Map.put("attachment", [
          %{
            "type" => "Link",
            "mediaType" => "link",
            "href" => url,
            "name" => "Described By The Sender",
            "summary" => "So there is nothing to go and fetch"
          }
        ])

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert [media] = Enum.filter(post.media, &(&1.path == url)),
             "one Media for the link, not one per place it appeared"

      assert Media.media_label(media) == "Described By The Sender",
             "the sender's title should survive, rather than being overwritten by a re-fetch"
    end
  end

  describe "link previews federate as a primary object" do
    # `Media.publish/3` is the other way a link reaches the network: the Media itself is the object of the activity (the comments_embed and GraphQL publish flows), rather than a post's attachment
    test "a link Media published on its own federates its title, description and cover image" do
      user = fake_user!()
      url = "https://example.com/standalone/article"

      assert {:ok, media} = link_media(user, url)

      assert {:ok, _} = Media.publish(user, media, boundary: "public")
      assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: media)

      assert data["name"] == "The Article Title"
      assert data["summary"] == "What the article is about"
      assert data["url"] == url
      assert data["image"]["url"] == "https://example.com/og.jpg"
    end

    test "a published link Media is attributed to its creator" do
      user = fake_user!()
      url = "https://example.com/standalone/attributed"

      assert {:ok, media} = link_media(user, url)

      assert {:ok, _} = Media.publish(user, media, boundary: "public")
      assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: media)

      {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

      assert data["attributedTo"] == actor.ap_id,
             "Mastodon & co. read authorship from `attributedTo` on the object, not from `actor`"
    end
  end
end
