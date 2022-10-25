defmodule Bonfire.Federate.ActivityPub.TwoInstances.FollowPostTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  alias Bonfire.Common.TestInstanceRepo

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows
  alias Bonfire.Federate.ActivityPub.Utils, as: IntegrationUtils

  setup_all do
    TestInstanceRepo.apply(fn ->
      # repo().delete_all(ActivityPub.Object)
      remote_user = fake_user!("B Remote #{Pointers.ULID.generate()}")

      [
        remote_user: remote_user,
        remote_user_info: [
          username: Bonfire.Me.Characters.display_username(remote_user, true),
          canonical_url: Bonfire.Me.Characters.character_url(remote_user),
          friendly_url: Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(remote_user)
        ]
      ]
    end)
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
        # FIXME? should we be getting a Post here rather than an Object?
        assert {:ok, object} = IntegrationUtils.get_by_url_ap_id_or_username(canonical_url)

        assert object.data["content"] =~ attrs.post_content.html_body

        assert {:ok, object} = IntegrationUtils.get_by_url_ap_id_or_username(friendly_url)

        assert object.data["content"] =~ attrs.post_content.html_body
      end)
  end

  @tag :test_instance
  test "can lookup from AP API with username, AP ID and with friendly URL",
       context do
    # TODO: lookup 3 separate users to be sure
    info(context[:remote_user_info][:username])

    assert {:ok, object} =
             IntegrationUtils.get_by_url_ap_id_or_username(context[:remote_user_info][:username])

    assert object.profile.name == context[:remote_user].profile.name

    assert {:ok, object} =
             IntegrationUtils.get_by_url_ap_id_or_username(
               context[:remote_user_info][:canonical_url]
             )

    assert object.profile.name == context[:remote_user].profile.name

    assert {:ok, object} =
             IntegrationUtils.get_by_url_ap_id_or_username(
               context[:remote_user_info][:friendly_url]
             )

    assert object.profile.name == context[:remote_user].profile.name
  end

  @tag :test_instance
  test "outgoing follow makes requests", context do
    local_follower = fake_user!("A Follower #{Pointers.ULID.generate()}")
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    remote_followed = context[:remote_user]
    followed_ap_id = context[:remote_user_info][:canonical_url]
    # {remote_followed, followed_ap_id} =
    #   TestInstanceRepo.apply(fn ->
    #     # repo().delete_all(ActivityPub.Object)
    #     remote_followed = fake_user!("B Followed #{Pointers.ULID.generate()}")
    #     {remote_followed, Bonfire.Me.Characters.character_url(remote_followed)}
    #   end)

    info(followed_ap_id, "followed_ap_id")

    assert {:ok, local_followed} = IntegrationUtils.get_or_fetch_and_create_by_uri(followed_ap_id)
    info(local_followed.character.username, "local_followed remote username")

    refute ulid(remote_followed) == ulid(local_followed)

    assert {:ok, request} = Follows.follow(local_follower, local_followed)
    info(request)

    assert Bonfire.Social.Follows.requested?(local_follower, local_followed)
    refute Bonfire.Social.Follows.following?(local_follower, local_followed)

    TestInstanceRepo.apply(fn ->
      info(follower_ap_id, "follower_ap_id")

      assert {:ok, remote_follower} =
               IntegrationUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      info(remote_follower.character.username, "remote_follower username")
      # dump(ActivityPub.Object.all())
      {:ok, _} = Bonfire.Me.Users.by_username(remote_follower.character.username)
      refute Bonfire.Social.Follows.following?(remote_follower, remote_followed)
      assert Bonfire.Social.Follows.requested?(remote_follower, remote_followed)
    end)
  end
end
