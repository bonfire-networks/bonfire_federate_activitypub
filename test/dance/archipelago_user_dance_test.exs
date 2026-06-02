defmodule Bonfire.Federate.ActivityPub.Dance.ArchipelagoUserDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub, as: Federation
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Boundaries.Allowlist

  setup context do
    on_exit(fn ->
      clean_slate(context)
    end)
  end

  # -----------------------------------------------------------------------
  # user-level allowlist-only mode (instance open)
  # -----------------------------------------------------------------------

  describe "user-level allowlist-only mode (instance open)" do
    test "DM from non-allowlisted actor is rejected", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      alice_local = set_user_allowlist_only(alice_local)
      {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice_local.id)

      text = "archipelago user allowlist DM rejected #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "message",
            to_circles: [alice_on_remote.id]
          )
      end)

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
               current_user: alice_local
             )
    end

    test "DM from allowlisted actor is received", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      alice_local = set_user_allowlist_only(alice_local)
      {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice_local.id)

      _bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      text = "archipelago user allowlist DM accepted #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "message",
            to_circles: [alice_on_remote.id]
          )
      end)

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
               current_user: alice_local
             )
    end

    test "DM from actor on allowlisted domain is received", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      alice_local = set_user_allowlist_only(alice_local)
      {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice_local.id)

      {:ok, instance_circle} = Instances.get_or_create_instance_circle(remote_host(context))
      Allowlist.allow(instance_circle, alice_local)

      text = "archipelago user allowlist domain DM accepted #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "message",
            to_circles: [alice_on_remote.id]
          )
      end)

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
               current_user: alice_local
             )
    end

    test "block overrides user allowlist — allowlisted + silenced = rejected", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      alice_local = set_user_allowlist_only(alice_local)
      {:ok, alice_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(alice_local.id)

      bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      assert {:ok, _} =
               Blocks.block(bob_remote_on_local, :silence, current_user: alice_local)

      text = "archipelago user block-overrides-allowlist DM #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "message",
            to_circles: [alice_on_remote.id]
          )
      end)

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
               current_user: alice_local
             )
    end
  end

  # -----------------------------------------------------------------------
  # instance allowlist-only + user allowlist aggregation
  # -----------------------------------------------------------------------

  describe "instance allowlist-only + user allowlist aggregation" do
    test "user can extend instance allowlist for incoming DM (actor allowlisted only at user level)",
         context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      # remote domain NOT in instance allowlist

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      _bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      text = "archipelago user extends instance allowlist DM #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "message",
            to_circles: [alice_on_remote.id]
          )
      end)

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
               current_user: alice_local
             )
    end

    test "public posts still require instance allowlist (user allowlist does not extend public feed)",
         context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      # remote domain NOT in instance allowlist

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      # alice allows bob personally but NOT the domain at instance level
      _bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      assert {:ok, _} = Follows.follow(alice_local, bob_remote_on_local)

      text = "archipelago user allowlist no-public-feed extension #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "public"
          )
      end)

      refute Bonfire.Social.FeedLoader.feed_contains?(:my, text, current_user: alice_local)
    end

    test "user can extend instance allowlist for outgoing DM", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      # remote domain NOT in instance allowlist

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      text = "archipelago user extends instance allowlist outgoing DM #{System.unique_integer()}"

      {:ok, _post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "message",
          to_circles: [bob_remote_on_local.id]
        )

      TestInstanceRepo.apply(fn ->
        assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
                 current_user: bob_remote
               )
      end)
    end

    test "outgoing DM to actor not in any allowlist is not delivered", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      # neither instance allowlist nor user allowlist includes bob

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      text = "archipelago outgoing DM not in allowlist #{System.unique_integer()}"

      {:ok, _post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "message",
          to_circles: [bob_remote_on_local.id]
        )

      TestInstanceRepo.apply(fn ->
        refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, text,
                 current_user: bob_remote
               )
      end)
    end
  end

  # -----------------------------------------------------------------------
  # allowlist affects follows (user-level)
  # -----------------------------------------------------------------------

  describe "allowlist affects follows (user-level)" do
    test "user in allowlist-only mode cannot follow non-allowlisted actor", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      alice_local = set_user_allowlist_only(alice_local)

      Follows.follow(alice_local, bob_remote_on_local)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        refute Follows.following?(alice_on_remote, bob_remote)
      end)
    end

    test "user in allowlist-only mode can follow allowlisted actor", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = allowlist_remote_actor(context, alice_local)

      alice_local = set_user_allowlist_only(alice_local)

      Follows.follow(alice_local, bob_remote_on_local)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        assert Follows.following?(alice_on_remote, bob_remote)
      end)
    end
  end
end
