defmodule Bonfire.Federate.ActivityPub.Dance.ModerationDanceTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows


  describe "if I silenced a remote user i will not receive any update from it" do
    test "i'll not see anything they publish in feeds", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]


      {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # alice follows bob_remote
      assert {:ok, _follow} = Follows.follow(alice_local, bob_remote_user_on_local)
      assert Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence, current_user: alice_local)
      attrs = "try out federated post"
      # on remote instance, bob_remote publish a post
      TestInstanceRepo.apply(fn ->

        post_attrs = %{post_content: %{html_body: attrs}}
        {:ok, post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: post_attrs,
            boundary: "public"
          )
      end)

      # on local instance, alice_local should not see the post
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: alice_local)
      # assert feed is empty
      assert a_remote = Enum.empty?(feed)
    end

    test "i'll be able to view their profile or read post via direct link", context do
      IO.inspect(context[:remote][:username], label: "TEST22")
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]


      {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # alice follows bob_remote
      assert {:ok, _follow} = Follows.follow(alice_local, bob_remote_user_on_local)
      assert Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence, current_user: alice_local)


      conn = conn(user: alice_local)
      assert {:ok, profile, _html} = live(conn, "/" <>  context[:remote][:username])

      attrs = "try out federated post"
      # on remote instance, bob_remote publish a post
      TestInstanceRepo.apply(fn ->

        post_attrs = %{post_content: %{html_body: attrs}}
        {:ok, post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: post_attrs,
            boundary: "public"
          )
      end)

    end

    test "i'll not see any @ mentions from them", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]


      {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # alice follows bob_remote
      assert {:ok, _follow} = Follows.follow(alice_local, bob_remote_user_on_local)
      assert Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence, current_user: alice_local)
      attrs = "#{context[:local][:username]} try out federated post"
      # on remote instance, bob_remote publish a post
      TestInstanceRepo.apply(fn ->

        post_attrs = %{post_content: %{html_body: attrs}}
        {:ok, post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: post_attrs,
            boundary: "mention"
          )
      end)

      # on local instance, alice_local should not see the post
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:notifications, current_user: alice_local)
      # assert feed is empty
      assert a_remote = Enum.empty?(feed)
    end

    test "i'll not see any  DM from them", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]
      alice_local_ap_id = context[:local][:canonical_url]


      {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # alice follows bob_remote
      assert {:ok, _follow} = Follows.follow(alice_local, bob_remote_user_on_local)
      assert Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence, current_user: alice_local)
      attrs = "#{context[:local][:username]} try out federated post"
      # on remote instance, bob_remote publish a post
      TestInstanceRepo.apply(fn ->
        {:ok, local_on_remote} =
          Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        post_attrs = %{post_content: %{html_body: attrs}}
        {:ok, post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: post_attrs,
            boundary: "message",
            to_circles: [local_on_remote.id]
          )
      end)

      # on local instance, alice_local should not see the post
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:inbox, current_user: alice_local)
      # assert feed is empty
      assert a_remote = Enum.empty?(feed)
    end

    test "I'll not be able to follow them" do
    end

  end

  describe "if I ghosted a remote user they will not be able to interact with me or with my content" do
    test "Nothing I post privately will be shown to them from now on", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote_ap_id = context[:local][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # on remote instance, bob_remote follows alice
      TestInstanceRepo.apply(fn ->
        {:ok, local_on_remote} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        assert {:ok, _follow} = Follows.follow(bob_remote, local_on_remote)
        assert Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      assert {:ok, _ghosted} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost, current_user: alice_local)
      attrs = "try out federated post"
      post_attrs = %{post_content: %{html_body: attrs}}
      {:ok, post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: post_attrs,
          boundary: "public"
        )


      # on remote instance, bob_remote should not see the post
      TestInstanceRepo.apply(fn ->
        assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: bob_remote)
        # assert feed is empty
        assert a_remote = Enum.empty?(feed)
      end)

    end

    # This is irrelevant - already tested
    # test "They will still be able to see things I post publicly.", context do

    # end

    test "I won't be able to @ mention them.", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote_ap_id = context[:local][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # on remote instance, bob_remote follows alice
      TestInstanceRepo.apply(fn ->
        {:ok, local_on_remote} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        assert {:ok, _follow} = Follows.follow(bob_remote, local_on_remote)
        assert Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      assert {:ok, _ghosted} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost, current_user: alice_local)
      attrs = "#{context[:remote][:username]} try out federated post"
      post_attrs = %{post_content: %{html_body: attrs}}
      {:ok, post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: post_attrs,
          boundary: "mention"
        )


      # on remote instance, bob_remote should not see the post
      TestInstanceRepo.apply(fn ->
        assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:notifications, current_user: bob_remote)
        # assert feed is empty
        assert a_remote = Enum.empty?(feed)
      end)
    end

    test "I won't be able to DM them.", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote_ap_id = context[:local][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)


      # on remote instance, bob_remote follows alice
      TestInstanceRepo.apply(fn ->
        {:ok, local_on_remote} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        assert {:ok, _follow} = Follows.follow(bob_remote, local_on_remote)
        assert Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      # assert {:ok, _ghosted} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost, current_user: alice_local)
      attrs = "#{context[:remote][:username]} try out federated post"
      post_attrs = %{post_content: %{html_body: attrs}}
      {:ok, post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: post_attrs,
          boundary: "message",
          to_circles: [bob_remote_user_on_local.id]
        )


      # on remote instance, bob_remote should not see the post
      TestInstanceRepo.apply(fn ->
        assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:inbox, current_user: bob_remote)
        # assert feed is empty
        assert a_remote = Enum.empty?(feed)
      end)
    end

    # test "they won't be able to follow me" do
    # end

  end

  describe "Admin" do
    test "As an admin I can ghost a remote user instance-wide" do
    end

    test "As an admin I can silence a remote user instance-wide" do
    end
  end
end
