defmodule Bonfire.Federate.ActivityPub.Simulate do
  use Bonfire.Common.E

  def fake_remote_user(actor_id \\ "https://mocked.local/users/karen") do
    Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(actor_json(actor_id))
  end

  # import Bonfire.Common.Simulation
  def actor_json("https://mocked.local/users/karen") do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://mocked.local/schemas/litepub-0.1.jsonld",
        %{"@language" => "und"}
      ],
      "attachment" => [
        %{
          "name" => "gf",
          "type" => "PropertyValue",
          "value" =>
            "<a rel=\"me\" href=\"https://nulled.local/@other\">https://nulled.local/@other</a>"
        }
      ],
      "discoverable" => false,
      "endpoints" => %{
        "oauthAuthorizationEndpoint" => "https://mocked.local/oauth/authorize",
        "oauthRegistrationEndpoint" => "https://mocked.local/api/v1/apps",
        "oauthTokenEndpoint" => "https://mocked.local/oauth/token",
        "sharedInbox" => "https://mocked.local/inbox",
        "uploadMedia" => "https://mocked.local/api/ap/upload_media"
      },
      "followers" => "https://mocked.local/users/karen/followers",
      "following" => "https://mocked.local/users/karen/following",
      "icon" => %{
        "type" => "Image",
        "url" =>
          "https://mocked.local/media/39fb9c0661e7de08b69163fee0eb99dee5fa399f2f75d695667cabfd9281a019.png?name=MKIOQWLTKDFA.png"
      },
      "id" => "https://mocked.local/users/karen",
      "image" => %{
        "type" => "Image",
        "url" =>
          "https://mocked.local/media/e05c7271-cd93-472a-97bd-46367f9709d7/CC0E8BA674C6519E9749C29C8883C30F3E348D6DAC558C13E4018BA385F7DA5C.jpeg"
      },
      "inbox" => "https://mocked.local/users/karen/inbox",
      "manuallyApprovesFollowers" => false,
      "name" => "test user",
      "outbox" => "https://mocked.local/users/karen/outbox",
      "preferredUsername" => "karen",
      "publicKey" => %{
        "id" => "https://mocked.local/users/karen#main-key",
        "owner" => "https://mocked.local/users/karen",
        "publicKeyPem" =>
          "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5FUojZbzUpD6L1Kof1gr\nh7GMSKd/N36FiekhhyDBAhtXgwEFgUWkiGLyDrNPP6RFFD/37FuZlq9JWSAonEHL\nbE4freE/FcuBP84AWQl/ZEm8BPCYVlHwALFEo13Gxg/VMetN37By0H7O7Lmb5JV4\nVgujqMaoNss03fwZARGd0LMLokN5KJExt7e1bsAqZOvI/xOBF1XlSRiHkco4OUGZ\nYjhoNbCKQtL995hGo14JlNd3QZI5RcBU47SqEuUYvgJXlyrVEKpqozBsFpGkh4/+\n9ck31bG50V3mLTL2SUthUdX9r8DgJVsxFYSb/rRMyPcCZAH8RD3FJH5deRtH1KJy\n7wIDAQAB\n-----END PUBLIC KEY-----\n\n"
      },
      "summary" =>
        "This is just a test user. <a class=\"hashtag\" data-tag=\"kawen\" href=\"https://mocked.local/tag/kawen\" rel=\"tag ugc\">#kawen</a>​",
      "tag" => [],
      "type" => "Person",
      "url" => "https://mocked.local/@karen"
    }
  end

  @doc """
  Fetches a real remote actor then corrupts their avatar/banner media paths to broken URLs,
  for manual browser testing of the image 404 → fallback + actor refetch flow.

  ## Usage in iex (`just iex`):

      Bonfire.Federate.ActivityPub.Simulate.fake_remote_user_broken_images!()

  Then visit the returned profile URL and observe:
  - Avatar: skeleton shows, then fallback icon appears after ~2s retry
  - Banner: CSS bg-image silently fails, refetch enqueued
  - Oban queue: a RemoteFetcherWorker job for the actor's AP ID
  """
  def fake_remote_user_broken_images!(
        ap_id \\ "https://bonfire.cafe/pub/actors/testing",
        opts \\ [avatar: true, banner: true]
      ) do
    {:ok, user} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(ap_id)

    Bonfire.Posts.publish(
      current_user: user,
      post_attrs: %{
        post_content: %{
          html_body: "<p>Test post to see avatar in feeds</p>"
        }
      },
      boundary: "public"
    )

    break_user_images!(user, opts)
  end

  @doc """
  Corrupts a user's avatar and/or banner media paths to broken URLs,
  for testing the image 404 → fallback + actor refetch flow.

  Options:
  - `avatar: true` — break the avatar (icon) URL
  - `banner: true` — break the banner (image) URL
  """
  def break_user_images!(user, opts \\ [avatar: true, banner: true]) do
    import Ecto.Query

    user = Bonfire.Common.Repo.preload(user, profile: [:icon, :image])
    profile = e(user, :profile, nil)

    if opts[:avatar] do
      icon_id = e(profile, :icon_id, nil) || e(profile, :icon, :id, nil)

      if icon_id do
        Bonfire.Common.Repo.update_all(
          from(m in Bonfire.Files.Media, where: m.id == ^icon_id),
          set: [path: "https://this-domain-does-not-exist-404.example/avatar.png"]
        )
      end
    end

    if opts[:banner] do
      image_id = e(profile, :image_id, nil) || e(profile, :image, :id, nil)

      if image_id do
        Bonfire.Common.Repo.update_all(
          from(m in Bonfire.Files.Media, where: m.id == ^image_id),
          set: [path: "https://this-domain-does-not-exist-404.example/banner.png"]
        )
      end
    end

    url = Bonfire.Me.Characters.character_url(user)
    IO.puts("\nVisit: http://localhost:4000#{url}\n")
    user
  end

  def webfingered() do
    %{
      "aliases" => [
        "https://mocked.local/users/karen"
      ],
      "links" => [
        %{
          "href" => "https://mocked.local/users/karen",
          "rel" => "self",
          "type" => "application/activity+json"
        }
      ],
      "subject" => "acct:karen@mocked.local"
    }
  end
end
