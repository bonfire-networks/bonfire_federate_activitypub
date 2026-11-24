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

      # a page to preview for the link only in a post's body: a failed fetch saves no preview
      %{method: :get, url: "https://example.com/only-in-the-body/article"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Only in the body</title></head><body></body></html>"
        }

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

  # Which image is the post's primary one decides, on the receiving Bonfire, whether an incoming `Page` is filed as a Post (no primary image) or as Media (`Media.ap_receive_activity/3`). Only an image whose metadata says `primary_image: true`, the cover the author ticked, goes in `image`; every other image goes in `attachment`.
  describe "the cover versus the other images" do
    defp upload_image(user, file, metadata \\ %{}) do
      assert {:ok, media} =
               Files.upload(Bonfire.Files.ImageUploader, user, file, %{metadata: metadata})

      media
    end

    defp publish_with(user, medias, opts \\ []) do
      assert {:ok, post} =
               Posts.publish(
                 [
                   current_user: user,
                   boundary: "public",
                   post_attrs: %{
                     post_content: %{name: opts[:title], html_body: "look at this"},
                     uploaded_media: medias
                   }
                 ] ++ if(opts[:group], do: [publish_in: uid(opts[:group])], else: [])
               )

      published_object(post)
    end

    test "without media the object has neither `image` nor `attachment`" do
      data = publish_with(fake_user!(), [])

      refute Map.has_key?(data, "image")
      refute Map.has_key?(data, "attachment")
    end

    test "one image that is not the cover is an attachment, and there is no `image`" do
      user = fake_user!()
      data = publish_with(user, [upload_image(user, Files.Simulation.image_file())])

      refute Map.has_key?(data, "image")
      assert [%{"type" => "Image"}] = List.wrap(data["attachment"])
    end

    test "two images that are not the cover are both attachments, and there is no `image`" do
      user = fake_user!()

      data =
        publish_with(user, [
          upload_image(user, Files.Simulation.image_file()),
          upload_image(user, Files.Simulation.image_with_exif_file())
        ])

      refute Map.has_key?(data, "image")
      assert [%{"type" => "Image"}, %{"type" => "Image"}] = List.wrap(data["attachment"])
    end

    test "one image flagged as the cover is the `image`, and not an attachment too" do
      user = fake_user!()

      data =
        publish_with(user, [
          upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true})
        ])

      assert %{"type" => "Image"} = data["image"]
      refute Map.has_key?(data, "attachment")
    end

    test "a cover plus another image: the cover is `image`, only the other is an attachment" do
      user = fake_user!()

      data =
        publish_with(user, [
          upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true}),
          upload_image(user, Files.Simulation.image_with_exif_file())
        ])

      assert %{"url" => cover_url} = data["image"]
      assert [%{"url" => other_url}] = List.wrap(data["attachment"])
      assert cover_url != other_url, "the cover is not repeated in the attachments"
    end

    test "the cover flag may be the string \"true\"" do
      user = fake_user!()

      data =
        publish_with(user, [
          upload_image(user, Files.Simulation.image_file(), %{"primary_image" => "true"})
        ])

      assert %{"type" => "Image"} = data["image"]
    end

    # the same checks on the object a titled post in a group produces, which is a `Page`
    test "a titled post in a group is a Page with `image` only when a cover is flagged" do
      user = fake_user!()
      group = Bonfire.Classify.Simulate.fake_group!(user)

      without_cover =
        publish_with(user, [upload_image(user, Files.Simulation.image_file())],
          title: "A thread",
          group: group
        )

      with_cover =
        publish_with(
          user,
          [upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true})],
          title: "A thread",
          group: group
        )

      assert without_cover["type"] == "Page"
      refute Map.has_key?(without_cover, "image")
      assert [%{"type" => "Image"}] = List.wrap(without_cover["attachment"])

      assert with_cover["type"] == "Page"
      assert %{"type" => "Image"} = with_cover["image"]
    end
  end

  # What Bonfire files an incoming titled `Page` as: Media when it has a primary image (`image.url`), a Post when it has none, whatever else it carries (`Media.ap_receive_activity/3`). A `Link` attachment is looked at first: with no `content` the Page is the link (Media), with `content` it is a post about the link (Post), which is Lemmy's shape. The objects come from what we publish ourselves, re-addressed to a remote author, so the cases follow what `ap_prepare_object_note/7` and `Files.ap_merge_media/2` really emit.
  describe "an incoming titled Page with media" do
    @public "https://www.w3.org/ns/activitystreams#Public"

    defp as_remote_create(object, suffix) do
      id = "https://mocked.local/objects/#{suffix}-#{System.unique_integer([:positive])}"

      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "id" => id <> "/activity",
        "actor" => @remote_actor,
        "to" => [@public],
        "object" =>
          object
          |> Map.drop(["audience", "context", "cc", "inReplyTo"])
          |> Map.merge(%{
            "id" => id,
            "attributedTo" => @remote_actor,
            "to" => [@public],
            "cc" => []
          })
      }
    end

    defp receive_incoming(create) do
      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(create)

      assert {:ok, received} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               # `prune: true` because what comes back is a Post or a Media, which don't share associations
               |> repo().maybe_preload([:post_content, :media], prune: true)

      received
    end

    defp titled_page(user, medias) do
      group = Bonfire.Classify.Simulate.fake_group!(user)
      data = publish_with(user, medias, title: "A thread title", group: group)
      assert data["type"] == "Page", "control: this is the Page we send into a group"
      data
    end

    test "with a title and text and no media is a Post" do
      user = fake_user!()

      received = titled_page(user, []) |> as_remote_create("page") |> receive_incoming()

      assert %Bonfire.Data.Social.Post{} = received
      assert e(received, :post_content, :name, nil) == "A thread title"
    end

    test "with a primary image is Media" do
      user = fake_user!()

      page =
        titled_page(user, [
          upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true})
        ])

      assert %Bonfire.Files.Media{} = page |> as_remote_create("cover") |> receive_incoming()
    end

    test "with a primary image and another image is Media" do
      user = fake_user!()

      page =
        titled_page(user, [
          upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true}),
          upload_image(user, Files.Simulation.image_with_exif_file())
        ])

      assert %Bonfire.Files.Media{} = page |> as_remote_create("cover-plus") |> receive_incoming()
    end

    test "with images but no primary image is a Post, and keeps them attached" do
      user = fake_user!()

      page =
        titled_page(user, [
          upload_image(user, Files.Simulation.image_file()),
          upload_image(user, Files.Simulation.image_with_exif_file())
        ])

      refute Map.has_key?(page, "image"), "control: no primary image"

      received = page |> as_remote_create("attachments") |> receive_incoming()

      assert %Bonfire.Data.Social.Post{} = received
      assert length(List.wrap(received.media)) == 2
    end

    # Lemmy sends a post's link (or image URL) as a `Link` attachment, and its thumbnail as `image`
    test "with a Link attachment and no text is Media, with text it is a Post" do
      link = %{
        "type" => "Link",
        "href" => "https://example.com/an-article",
        "mediaType" => "text/html"
      }

      page = fn content ->
        %{
          "type" => "Page",
          "name" => "A link post",
          "content" => content,
          "attachment" => [link],
          "image" => %{"type" => "Image", "url" => "https://example.com/thumb.png"}
        }
      end

      assert %Bonfire.Files.Media{} =
               page.(nil) |> as_remote_create("link-bare") |> receive_incoming()

      assert %Bonfire.Data.Social.Post{} =
               page.("<p>and what I think of it</p>")
               |> as_remote_create("link-text")
               |> receive_incoming()
    end

    test "control: a Note with a title and a primary image is a Post" do
      user = fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 boundary: "public",
                 post_attrs: %{
                   post_content: %{name: "A title, no group", html_body: "look at this"},
                   uploaded_media: [
                     upload_image(user, Files.Simulation.image_file(), %{"primary_image" => true})
                   ]
                 }
               )

      note = published_object(post)
      assert note["type"] == "Note"

      assert %Bonfire.Data.Social.Post{} = note |> as_remote_create("note") |> receive_incoming()
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
    # FEP-8967: the `Link` has its `href` and its title as `name` (as AS2's own `Link` does), and what we resolved for the link goes in its `preview`
    test "a link-preview Media attached to a post federates its title, and its title, description and cover image in its preview" do
      user = fake_user!()
      url = "https://example.com/some/article"

      assert {:ok, media} = link_media(user, url)

      assert {:ok, post} = post_with(user, media, "worth a read: #{url}")

      data = published_object(post)

      assert [attachment] =
               List.wrap(data["attachment"])
               |> Enum.filter(&(&1["href"] == url or &1["url"] == url))

      assert attachment["type"] == "Link"
      assert attachment["name"] == "The Article Title"
      refute Map.has_key?(attachment, "summary")
      refute Map.has_key?(attachment, "image")

      assert attachment["preview"]["name"] == "The Article Title"
      assert attachment["preview"]["summary"] == "What the article is about"

      assert attachment["preview"]["image"]["url"] == "https://example.com/og.jpg",
             "the cover image we resolved for the link should not have to be re-fetched remotely"

      assert attachment["preview"]["type"] == "Page"
    end

    # the `preview`'s `type` tells a receiver the link plays, so it fetches the player from the provider itself
    test "a link to a player federates as a Video preview, with its author" do
      user = fake_user!()
      url = "https://video.example.com/w/a-player"

      assert {:ok, media} =
               Files.save_url_as_media(user, url, %{
                 media_type: "link",
                 metadata: %{
                   "label" => "A Video",
                   "oembed" => %{
                     "type" => "video",
                     "html" =>
                       ~s(<iframe src="https://video.example.com/embed/a-player"></iframe>),
                     "author_name" => "A Channel",
                     "author_url" => "https://video.example.com/c/a-channel"
                   }
                 }
               })

      assert {:ok, post} = post_with(user, media, "watch: #{url}")

      assert [attachment] =
               List.wrap(published_object(post)["attachment"])
               |> Enum.filter(&(&1["href"] == url))

      assert attachment["preview"]["type"] == "Video"
      assert attachment["preview"]["name"] == "A Video"
      assert attachment["preview"]["attributedTo"]["name"] == "A Channel"

      assert attachment["preview"]["attributedTo"]["url"]["href"] ==
               "https://video.example.com/c/a-channel"
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

  @player_page "https://video.example.com/w/incoming-player"
  @player_oembed %{
    "version" => "1.0",
    "type" => "video",
    "title" => "The Provider's Title",
    "html" => ~s(<iframe src="https://video.example.com/embed/incoming-player"></iframe>)
  }

  # each page a test serves, and a message to the test when it's fetched
  defp mock_pages(pages) do
    test = self()
    # Faviconic fetches with Req, which Tesla.Mock doesn't intercept
    Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)

    mock(fn
      %{method: :get, url: "https://video.example.com/oembed" <> _} = env ->
        send(test, {:fetched, env.url})

        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(@player_oembed)
        }

      %{method: :get, url: url} = env ->
        case Map.fetch(pages, url) do
          {:ok, body} ->
            send(test, {:fetched, url})
            %Tesla.Env{env | status: 200, headers: [{"content-type", "text/html"}], body: body}

          :error ->
            apply(ActivityPub.Test.HttpRequestMock, :request, [env])
        end

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)
  end

  defp player_page_html do
    ~s(<html><head><title>The Provider's Title</title><link rel="alternate" type="application/json+oembed" href="https://video.example.com/oembed?url=#{URI.encode_www_form(@player_page)}&amp;format=json"></head><body></body></html>)
  end

  defp receive_with_attachment(attachment) do
    data =
      "../fixtures/pixelfed-image.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("attachment", [attachment])

    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

    assert {:ok, post} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
             |> repo().maybe_preload([:post_content, :media])

    post
  end

  # FEP-8967: what a sender resolved for a link comes in its `preview`, and `preview.type` says whether the page plays. A player is fetched from the provider (never embedded from what the sender sent); other links keep what was sent, unfetched
  describe "incoming FEP-8967 link previews" do
    test "a link whose preview is a Video is fetched, and gets the provider's player" do
      mock_pages(%{@player_page => player_page_html()})

      post =
        receive_with_attachment(%{
          "type" => "Link",
          "href" => @player_page,
          "preview" => %{"type" => "Video", "name" => "The Sender's Title"}
        })

      assert_received {:fetched, @player_page}
      assert [media] = Enum.filter(post.media, &(&1.path == @player_page))
      assert %{"type" => "video", "html" => html} = media.metadata["oembed"]
      assert html =~ "https://video.example.com/embed/incoming-player"
    end

    test "control: a link whose preview is a Page keeps what was sent, unfetched" do
      url = "https://example.com/a-described-page"
      mock_pages(%{url => "<html><head><title>Fetched Title</title></head></html>"})

      post =
        receive_with_attachment(%{
          "type" => "Link",
          "href" => url,
          "preview" => %{
            "type" => "Page",
            "name" => "The Sender's Title",
            "summary" => "What the sender says it's about",
            "image" => %{"type" => "Image", "url" => "https://example.com/sender-cover.jpg"}
          }
        })

      refute_received {:fetched, _}
      assert [media] = Enum.filter(post.media, &(&1.path == url))
      assert Media.media_label(media) == "The Sender's Title"
      assert Media.description(media) == "What the sender says it's about"
      assert Media.preview_image_url(media) == "https://example.com/sender-cover.jpg"
    end

    # an older Bonfire (and AS2's own `Link`) puts the details at the top level
    test "a link with its details only at the top level keeps them, unfetched" do
      url = "https://example.com/a-top-level-page"
      mock_pages(%{url => "<html><head><title>Fetched Title</title></head></html>"})

      post =
        receive_with_attachment(%{
          "type" => "Link",
          "href" => url,
          "name" => "The Top Title",
          "summary" => "The top summary",
          "image" => %{"type" => "Image", "url" => "https://example.com/top-cover.jpg"}
        })

      refute_received {:fetched, _}
      assert [media] = Enum.filter(post.media, &(&1.path == url))
      assert Media.media_label(media) == "The Top Title"
      assert Media.description(media) == "The top summary"
      assert Media.preview_image_url(media) == "https://example.com/top-cover.jpg"
    end

    test "a link with details both at the top level and in its preview uses the preview's, unfetched" do
      url = "https://example.com/a-page-with-both"
      mock_pages(%{url => "<html><head><title>Fetched Title</title></head></html>"})

      post =
        receive_with_attachment(%{
          "type" => "Link",
          "href" => url,
          "name" => "The Top Title",
          "summary" => "The top summary",
          "image" => %{"type" => "Image", "url" => "https://example.com/top-cover.jpg"},
          "preview" => %{
            "type" => "Page",
            "name" => "The Preview Title",
            "summary" => "The preview summary",
            "image" => %{"type" => "Image", "url" => "https://example.com/preview-cover.jpg"}
          }
        })

      refute_received {:fetched, _}
      assert [media] = Enum.filter(post.media, &(&1.path == url))
      assert Media.media_label(media) == "The Preview Title"
      assert Media.description(media) == "The preview summary"
      assert Media.preview_image_url(media) == "https://example.com/preview-cover.jpg"
    end

    test "a Mastodon-shaped link (only its href) is fetched" do
      url = "https://example.com/a-bare-link"
      mock_pages(%{url => "<html><head><title>Fetched Title</title></head></html>"})

      post = receive_with_attachment(%{"type" => "Link", "href" => url})

      assert_received {:fetched, ^url}
      assert [_] = Enum.filter(post.media, &(&1.path == url))
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

  # each delivery gets its own file URLs (`/files/redir/f/<target>/…`), in every place the object has them, so the ones in `content` still match the ones in `attachment`
  describe "file URLs rewritten per delivery" do
    @file_url "https://bonfire.local/files/redir/local/data/uploads/u/images/a.png"
    @cover_url "https://bonfire.local/files/redir/local/data/uploads/u/images/cover.png"

    test "an object with a cover gets its image, its attachment and its content rewritten" do
      data = %{
        "image" => %{"type" => "Image", "url" => @cover_url},
        "attachment" => [%{"type" => "Image", "url" => @file_url}],
        "content" => ~s(<p>a</p><p><img src="#{@file_url}"></p>)
      }

      out =
        Bonfire.Federate.ActivityPub.Adapter.transform_outgoing(data, "remote.example", nil)

      assert out["image"]["url"] =~ "/files/redir/f/"
      assert [%{"url" => attachment_url}] = out["attachment"]
      assert attachment_url =~ "/files/redir/f/"
      assert out["content"] =~ ~s(src="#{attachment_url}")
    end

    test "an object without a cover gets its attachment and its content rewritten" do
      data = %{
        "attachment" => [%{"type" => "Image", "url" => @file_url}],
        "content" => ~s(<p><img src="#{@file_url}"></p>)
      }

      out =
        Bonfire.Federate.ActivityPub.Adapter.transform_outgoing(data, "remote.example", nil)

      assert [%{"url" => attachment_url}] = out["attachment"]
      assert attachment_url =~ "/files/redir/f/"
      assert out["content"] =~ ~s(src="#{attachment_url}")
    end
  end

  # FEP-b2b8 has media embedded in `content` also listed in `attachment`, with the same URL: shown once, where the body has it, not again in the attachment list (see `Bonfire.Files.InlineMedia`)
  describe "an incoming body that shows one of its attachments" do
    @inline_image @remote_instance <> "/media/inline.png"
    @other_image @remote_instance <> "/media/other.png"

    defp article_with_image_in_body(attachment_urls) do
      %{
        "type" => "Article",
        "name" => "An article",
        "content" => ~s(<p>a</p><img src="#{@inline_image}"><p>b</p>),
        "attachment" =>
          for url <- attachment_urls do
            %{"type" => "Image", "mediaType" => "image/png", "url" => url}
          end
      }
    end

    test "the attachment whose URL is an image in the body is placed by the body, and the body is kept" do
      received =
        article_with_image_in_body([@inline_image, @other_image])
        |> as_remote_create("inline-image")
        |> receive_incoming()

      body = e(received, :post_content, :html_body, nil)
      media = e(received, :media, [])

      assert body =~ ~s(src="#{@inline_image}")
      assert [%{path: @inline_image}] = Bonfire.Files.InlineMedia.placed(media, body)
    end

    test "a link alone in its paragraph in an HTML body places its attachment, and the body is cut there" do
      received =
        %{
          "type" => "Article",
          "name" => "An article",
          "content" => ~s(<p>a</p><p><a href="#{@other_image}">#{@other_image}</a></p><p>b</p>),
          "attachment" => [
            %{"type" => "Image", "mediaType" => "image/png", "url" => @other_image}
          ]
        }
        |> as_remote_create("linked-image")
        |> receive_incoming()

      body = e(received, :post_content, :html_body, nil)

      assert [%{path: @other_image}] =
               Bonfire.Files.InlineMedia.placed(e(received, :media, []), body)

      assert [{:html, _}, {:url, @other_image}, {:html, _}] =
               Bonfire.Common.Text.markdown_parts(body, MapSet.new([@other_image]), [])
    end

    # the sanitiser drops `iframe`, `video` and `audio`: each becomes a link where it was, so the body keeps the player's place
    for {player, url} <- [
          {~s(<iframe src="https://video.example.com/videos/embed/x" title="A video"></iframe>),
           "https://video.example.com/videos/embed/x"},
          {~s(<video controls><source src="https://video.example.com/v.mp4" type="video/mp4"></video>),
           "https://video.example.com/v.mp4"},
          {~s(<audio src="https://audio.example.com/a.mp3"></audio>),
           "https://audio.example.com/a.mp3"}
        ] do
      test "an incoming #{player |> String.split(" ") |> hd()}> becomes a link where it was" do
        received =
          %{
            "type" => "Article",
            "name" => "An article",
            "content" => "<p>a</p>#{unquote(player)}<p>b</p>"
          }
          |> as_remote_create("player")
          |> receive_incoming()

        assert e(received, :post_content, :html_body, nil) =~
                 ~r/<p>a<\/p>.*<a [^>]*href="#{Regex.escape(unquote(url))}".*<p>b<\/p>/s
      end
    end

    test "control: a player with a script or relative source leaves nothing, as before" do
      received =
        %{
          "type" => "Article",
          "name" => "An article",
          "content" =>
            ~s|<p>a</p><iframe src="javascript:alert(1)"></iframe><iframe src="/local/x"></iframe><p>b</p>|
        }
        |> as_remote_create("bad-player")
        |> receive_incoming()

      body = e(received, :post_content, :html_body, nil)
      refute body =~ "javascript:"
      refute body =~ "/local/x"
    end

    test "control: an attachment that isn't in the body isn't placed" do
      received =
        article_with_image_in_body([@other_image])
        |> as_remote_create("inline-image-control")
        |> receive_incoming()

      assert Bonfire.Files.InlineMedia.placed(
               e(received, :media, []),
               e(received, :post_content, :html_body, nil)
             ) == []
    end
  end
end
