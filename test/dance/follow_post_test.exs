defmodule Bonfire.Federate.ActivityPub.Dance.FollowPostTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  def fake_remote!() do
    TestInstanceRepo.apply(fn ->
      # repo().delete_all(ActivityPub.Object)
      remote_user = fake_user!("B Remote #{Pointers.ULID.generate()}")

      [
        user: remote_user,
        username: Bonfire.Me.Characters.display_username(remote_user, true),
        canonical_url: Bonfire.Me.Characters.character_url(remote_user),
        friendly_url: Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(remote_user)
      ]
    end)
  end

  setup_all do
    [
      remote: fake_remote!()
    ]
  end

  @tag :test_instance
  test "can fetch public post from AP API with AP ID and with friendly URL and Accept header",
       _context do
    user = fake_user!("poster #{Pointers.ULID.generate()}")
    attrs = %{post_content: %{html_body: "test content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    friendly_url =
      (Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(post))
      |> info("friendly_url")

    post =
      TestInstanceRepo.apply(fn ->
        # FIXME? should we be receiving a Post here rather than an Object?
        assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(canonical_url)

        assert object.data["content"] =~ attrs.post_content.html_body

        assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(friendly_url)

        assert object.data["content"] =~ attrs.post_content.html_body
      end)
  end

  @tag :test_instance
  test "can lookup from AP API with username, AP ID and with friendly URL",
       _context do
    # lookup 3 separate users to be sure

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

    assert object.profile.name == remote[:user].profile.name

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

    assert object.profile.name == remote[:user].profile.name

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

    assert object.profile.name == remote[:user].profile.name
  end

  @tag :test_instance
  test "remote follow makes a request, which user can accept and then it turns into a follow",
       context do
    local_follower = fake_user!("A Follower #{Pointers.ULID.generate()}")
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    followed_ap_id = context[:remote][:canonical_url]

    info(followed_ap_id, "followed_ap_id")

    assert {:ok, followed_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(followed_ap_id)

    Logger.metadata(action: info("make a (request to) follow"))
    assert {:ok, request} = Follows.follow(local_follower, followed_on_local)
    request_id = ulid(request)
    info(request, "the request")

    assert Follows.requested?(local_follower, followed_on_local) |> info()
    refute Follows.following?(local_follower, followed_on_local) |> info()

    # this shouldn't be needed if running Oban :inline
    Bonfire.Common.Config.get([:bonfire, Oban]) |> info("obannn")
    # Oban.drain_queue(queue: :federator_outgoing)
    # assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(request)
    assert %{__struct__: ActivityPub.Object, pointer_id: ^request_id} =
             Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("check request received on remote"))

      remote_followed = context[:remote][:user]

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      assert ulid(follower_on_remote) != ulid(local_follower)
      assert ulid(remote_followed) != ulid(followed_on_local)

      assert Follows.requested?(follower_on_remote, remote_followed)
      refute Follows.following?(follower_on_remote, remote_followed)

      Logger.metadata(action: info("accept request"))

      assert {:ok, follow} =
               Follows.accept_from(follower_on_remote, current_user: remote_followed)

      Logger.metadata(action: info("check request is now a follow on remote"))
      assert Follows.following?(follower_on_remote, remote_followed)
      refute Follows.requested?(follower_on_remote, remote_followed)

      # Logger.metadata(action: info("make a post on remote"))

      # attrs = %{post_content: %{html_body: "test content"}}
      # {:ok, post} = Posts.publish(current_user: remote_followed, post_attrs: attrs, boundary: "public")
    end)

    Logger.metadata(action: info("check accept was received and local is now following"))
    assert Follows.following?(local_follower, followed_on_local)
    refute Follows.requested?(local_follower, followed_on_local)

    # Logger.metadata(action: info("TODO: check that the post was federated and is in feed"))
  end
end
