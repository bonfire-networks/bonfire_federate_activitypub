defmodule Bonfire.Federate.ActivityPub.Dance.RemoteBoundariesDanceTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance
  @moduletag :mneme

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.{Circles, Acls, Grants, Blocks}
  use Mneme

  setup context do
    # clean_slate(context)
    on_exit(fn ->
      clean_slate(context)
    end)
  end

  def clean_slate(context) do
    do_clean_slate(context[:local][:user], context[:remote][:canonical_url])

    # on remote instance, bob_remote follows alice
    TestInstanceRepo.apply(fn ->
      do_clean_slate(context[:remote][:user], context[:local][:canonical_url])
    end)

    :ok
  end

  def do_clean_slate(local, remote) do
    Config.put([:activity_pub, :instance, :federating], true)

    # repo().query("delete from ap_object", [])
    ActivityPub.Utils.cache_clear()

    {:ok, remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(remote)

    Blocks.unblock(local, remote_user_on_local)
    Blocks.unblock(remote_user_on_local, local)

    Follows.unfollow(local, remote_user_on_local)

    # Follows.unfollow(local, remote_user_on_local)
  end

  describe "if I silenced a remote user i will not receive any update from it" do
    test "i'll not see anything they publish in feeds", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      # alice follows bob_remote
      auto_assert {:ok, _} <-
                    Follows.follow(alice_local, bob_remote_user_on_local)

      # auto_assert {:error, :not_found} <-
      #               Follows.accept_from(alice_local, current_user: bob_remote_user_on_local)

      Logger.metadata(action: info("check request is now a follow on remote"))
      auto_assert true <- Follows.following?(alice_local, bob_remote_user_on_local)
      # auto_assert false <- Follows.requested?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      auto_assert {:ok, "Blocked"} <-
                    Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence,
                      current_user: alice_local
                    )

      attrs = "try out federated post 83"
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
      refute FeedActivities.feed_contains?(:local, attrs, current_user: alice_local)
      # assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: alice_local)
      # # assert feed is empty
      # auto_assert true <- Enum.empty?(feed)
    end

    test "i'll be able to view their profile or read post via direct link", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      # alice follows bob_remote
      auto_assert {:ok, _} <-
                    Follows.follow(alice_local, bob_remote_user_on_local)

      auto_assert true <- Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      auto_assert {:ok, "Blocked"} <-
                    Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence,
                      current_user: alice_local
                    )

      conn = conn(user: alice_local)
      assert {:ok, profile, _html} = live(conn, "/" <> context[:remote][:username])

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
      auto_assert {:ok, _} <-
                    Follows.follow(alice_local, bob_remote_user_on_local)

      auto_assert true <- Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} =
               Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence,
                 current_user: alice_local
               )

      attrs = "#{context[:local][:username]} try out federated post 162"
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
      refute FeedActivities.feed_contains?(:notifications, attrs, current_user: alice_local)
      # assert %{edges: feed} =
      #          Bonfire.Social.FeedActivities.feed(:notifications, current_user: alice_local)

      # # assert feed is empty
      # assert a_remote = Enum.empty?(feed)
    end

    test "i'll not see any DM from them", context do
      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]

      bob_remote_ap_id = context[:remote][:canonical_url]
      alice_local_ap_id = context[:local][:canonical_url]

      {:ok, bob_remote_user_on_local} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      # alice follows bob_remote
      assert {:ok, _follow} =
               Follows.follow(alice_local, bob_remote_user_on_local)
               |> debug("faaa")

      auto_assert true <- Follows.following?(alice_local, bob_remote_user_on_local)

      # alice silences bob_remote
      assert {:ok, _silenced} =
               Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :silence,
                 current_user: alice_local
               )

      attrs = "#{context[:local][:username]} try out federated post 207"
      # on remote instance, bob_remote publish a post
      TestInstanceRepo.apply(fn ->
        {:ok, local_on_remote} =
          Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
            alice_local_ap_id
          )

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
      refute FeedActivities.feed_contains?(:inbox, attrs, current_user: alice_local)
      # assert %{edges: feed} =
      #          Bonfire.Social.FeedActivities.feed(:inbox, current_user: alice_local)
      # # assert feed is empty
      # auto_assert true <- Enum.empty?(feed)
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
          Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
            alice_local_ap_id
          )

        auto_assert {:ok, _} <-
                      Follows.follow(bob_remote, local_on_remote)

        # auto_assert {:error, :not_found} <-
        #               Follows.accept_from(bob_remote, current_user: local_on_remote)

        auto_assert true <- Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      auto_assert {:ok, "Blocked"} <-
                    Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost,
                      current_user: alice_local
                    )

      attrs = "try out federated post 271"
      post_attrs = %{post_content: %{html_body: attrs}}

      {:ok, post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: post_attrs,
          boundary: "public"
        )

      # on remote instance, bob_remote should not see the post
      TestInstanceRepo.apply(fn ->
        refute FeedActivities.feed_contains?(:my, attrs, current_user: bob_remote)

        # assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: bob_remote)
        # # assert feed is empty
        # auto_assert false <- Enum.empty?(feed)
      end)
    end

    # This is irrelevant - already tested
    # test "They may still be able to see things I post publicly.", context do
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
          Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
            alice_local_ap_id
          )

        assert {:ok, _follow} = Follows.follow(bob_remote, local_on_remote)
        assert Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      assert {:ok, _ghosted} =
               Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost,
                 current_user: alice_local
               )

      attrs = "#{context[:remote][:username]} try out federated post 321"
      post_attrs = %{post_content: %{html_body: attrs}}

      {:ok, post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: post_attrs,
          boundary: "mention"
        )

      # on remote instance, bob_remote should not see the post
      TestInstanceRepo.apply(fn ->
        refute FeedActivities.feed_contains?(:notifications, attrs, current_user: bob_remote)
        # assert %{edges: feed} =
        #          Bonfire.Social.FeedActivities.feed(:notifications, current_user: bob_remote)
        # # assert feed is empty
        # assert a_remote = Enum.empty?(feed)
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
          Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
            alice_local_ap_id
          )

        assert {:ok, _follow} = Follows.follow(bob_remote, local_on_remote)
        assert Follows.following?(bob_remote, local_on_remote)
      end)

      # alice ghosts bob_remote
      # assert {:ok, _ghosted} = Bonfire.Boundaries.Blocks.block(bob_remote_user_on_local, :ghost, current_user: alice_local)
      attrs = "#{context[:remote][:username]} try out federated post 364"
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
        refute FeedActivities.feed_contains?(:inbox, attrs, current_user: bob_remote)
        # assert %{edges: feed} =
        #          Bonfire.Social.FeedActivities.feed(:inbox, current_user: bob_remote)
        # # assert feed is empty
        # assert a_remote = Enum.empty?(feed)
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

  test "custom with circle containing remote users permitted", context do
    attrs = "try out federated post with circle containing remote users 398"

    post1_attrs = %{
      post_content: %{html_body: attrs}
    }

    alice_local = context[:local][:user]
    bob_remote = context[:remote][:user]

    alice_local_ap_id = context[:local][:canonical_url]
    bob_remote_ap_id = context[:local][:canonical_url]

    {:ok, bob_remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

    # create a circle with bob_remote in it
    {:ok, circle} = Circles.create(alice_local, %{named: %{name: "family"}})
    {:ok, _} = Circles.add_to_circles(bob_remote_user_on_local.id, circle)

    # on remote instance, bob_remote follows alice_local
    TestInstanceRepo.apply(fn ->
      {:ok, local_from_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_local_ap_id)

      Follows.follow(bob_remote, local_from_remote)
      |> debug("ffffoo")

      auto_assert true <- Follows.following?(bob_remote, local_from_remote)
    end)

    # auto_assert Follows.following?(bob_remote_user_on_local, alice_local)

    # on local instance, alice_local create a post with circle
    {:ok, post1} =
      Posts.publish(
        current_user: alice_local,
        post_attrs: post1_attrs,
        boundary: "public",
        to_circles: %{circle.id => "interact"}
      )

    # on remote instance, bob_remote should see the post
    TestInstanceRepo.apply(fn ->
      assert FeedActivities.feed_contains?(:my, attrs, current_user: bob_remote)

      #   assert %Paginator.Page{edges: [feed_entry | _]} =
      #          Bonfire.Social.FeedActivities.feed(:my, current_user: bob_remote)
      #          |> debug("bob feed")

      # post1remote = feed_entry.activity.object

      # auto_assert true <-
      #               post1remote.post_content.html_body =~
      #                 "try out federated post with circle containing remote users"
    end)
  end
end
