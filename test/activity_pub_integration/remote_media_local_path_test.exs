defmodule Bonfire.Federate.ActivityPub.RemoteMediaLocalPathTest do
  @moduledoc """
  A remote actor's `icon`/`image` and an incoming Note's `attachment` may only name a remote URL. One that is a path on this server (`@local` is an image that really exists) must not be copied into our storage and served from it.

  Each input is paired with the same shape as a remote URL, which proves the media is made when it is allowed.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation
  import Tesla.Mock

  @instance "https://mocked.local"
  @actor_local @instance <> "/users/pathy"
  @actor_remote @instance <> "/users/urly"
  @poster "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @local Bonfire.Files.Simulation.icon_file().path
  @remote_icon @instance <> "/assets/urly_icon.png"
  @remote_image @instance <> "/assets/urly_banner.png"
  @remote_attachment @instance <> "/media/334ce029e7bfb920.png"

  setup_all do
    mock_global(fn
      %{method: :get, url: @actor_local} ->
        json(
          Simulate.actor_json(@actor_local, "pathy", %{
            "icon" => %{"type" => "Image", "mediaType" => "image/png", "url" => @local},
            "image" => %{"type" => "Image", "mediaType" => "image/png", "url" => @local}
          })
        )

      %{method: :get, url: @actor_remote} ->
        json(
          Simulate.actor_json(@actor_remote, "urly", %{
            "icon" => %{"type" => "Image", "mediaType" => "image/png", "url" => @remote_icon},
            "image" => %{"type" => "Image", "mediaType" => "image/png", "url" => @remote_image}
          })
        )

      %{method: :get, url: @poster} ->
        json(Simulate.actor_json(@poster))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp user_for(ap_id) do
    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
    {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    Bonfire.Common.Repo.preload(user, profile: [:icon, :image])
  end

  defp receive_note(attachment_url) do
    id = "#{@poster}/notes/#{Needle.UID.generate()}"

    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "id" => id <> "/create",
        "actor" => @poster,
        "to" => [@public],
        "object" => %{
          "type" => "Note",
          "id" => id,
          "attributedTo" => @poster,
          "content" => "a note with an image",
          "to" => [@public],
          "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "attachment" => [
            %{
              "type" => "Document",
              "mediaType" => "image/png",
              "name" => "an image",
              "url" => attachment_url
            }
          ]
        }
      })

    {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    Bonfire.Common.Repo.preload(post, files: :media)
  end

  test "a remote actor's icon and image that are remote urls are kept" do
    user = user_for(@actor_remote)

    assert user.profile.icon.path == @remote_icon
    assert user.profile.image.path == @remote_image
  end

  test "a remote actor's icon and image that are paths on this server are refused" do
    user = user_for(@actor_local)

    refute user.profile.icon_id
    refute user.profile.image_id
  end

  test "an incoming Note's attachment that is a remote url is kept" do
    assert [%{media: %{path: @remote_attachment}}] = receive_note(@remote_attachment).files
  end

  test "an incoming Note's attachment that is a path on this server is refused" do
    assert [] == receive_note(@local).files
  end
end
