defmodule Bonfire.Federate.ActivityPub.Dance.ArchipelagoDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub, as: Federation

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.{Circles, Blocks}
  alias Bonfire.Boundaries.Allowlist
  alias Bonfire.Common.Settings
  alias Bonfire.Common.URIs

  setup context do
    on_exit(fn ->
      clean_slate(context)
    end)
  end

  def clean_slate(context) do
    do_clean_slate(context[:local][:user], context[:remote][:canonical_url])

    TestInstanceRepo.apply(fn ->
      do_clean_slate(context[:remote][:user], context[:local][:canonical_url])
    end)

    :ok
  end

  def do_clean_slate(local, remote) do
    Federation.set_allowlist_only(:instance, false)

    local =
      current_user(Settings.put([:activity_pub, :user_federating], true, current_user: local))

    ActivityPub.Utils.cache_clear()

    {:ok, remote_user_on_local} =
      AdapterUtils.get_by_url_ap_id_or_username(remote)

    Blocks.unblock(local, remote_user_on_local)
    Blocks.unblock(remote_user_on_local, local)
    Follows.unfollow(local, remote_user_on_local)

    # unallow anything we may have allowed at user level
    Allowlist.unallow(remote_user_on_local, local)

    remote_host = URIs.base_domain(remote)

    with {:ok, instance_circle} <- Instances.get_or_create_instance_circle(remote_host) do
      Allowlist.unallow(instance_circle)
    end
  end

  defp get_remote_on_local(context) do
    {:ok, user} =
      AdapterUtils.get_by_url_ap_id_or_username(context[:remote][:canonical_url])

    user
  end

  defp get_local_on_remote(context) do
    TestInstanceRepo.apply(fn ->
      {:ok, user} =
        AdapterUtils.get_by_url_ap_id_or_username(context[:local][:canonical_url])

      user
    end)
  end

  defp remote_host(context), do: Bonfire.Common.URIs.base_domain(context[:remote][:canonical_url])

  defp allowlist_remote_instance(context) do
    {:ok, instance_circle} = Instances.get_or_create_instance_circle(remote_host(context))
    assert {:ok, _} = Allowlist.allow(instance_circle)
    instance_circle
  end

  defp allowlist_remote_actor(context, local_user) do
    bob_remote_on_local = get_remote_on_local(context)
    assert {:ok, _} = Allowlist.allow(bob_remote_on_local, local_user)
    bob_remote_on_local
  end

  defp set_user_allowlist_only(user) do
    current_user(
      Settings.put([:activity_pub, :user_federating], :allowlist_only, current_user: user)
    )
  end

  # -----------------------------------------------------------------------
  # instance-level allowlist-only mode — domain allowlisting
  # -----------------------------------------------------------------------

  describe "instance-level allowlist-only mode — domain allowlisting" do
    test "incoming from non-allowlisted domain is rejected", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      assert {:ok, _} = Follows.follow(alice_local, bob_remote_on_local)

      Federation.set_allowlist_only(:instance, true)

      text = "archipelago non-allowlisted incoming #{System.unique_integer()}"

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

    test "incoming from allowlisted domain is received", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      allowlist_remote_instance(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      assert {:ok, _} = Follows.follow(alice_local, bob_remote_on_local)

      text = "archipelago allowlisted domain incoming #{System.unique_integer()}"

      TestInstanceRepo.apply(fn ->
        {:ok, _post} =
          Posts.publish(
            current_user: bob_remote,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "public"
          )
      end)

      assert Bonfire.Social.FeedLoader.feed_contains?(:my, text, current_user: alice_local)
    end

    test "outgoing to non-allowlisted domain is not delivered", context do
      clean_slate(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        Follows.follow(bob_remote, alice_on_remote)
      end)

      Federation.set_allowlist_only(:instance, true)

      text = "archipelago non-allowlisted outgoing #{System.unique_integer()}"

      {:ok, _post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      TestInstanceRepo.apply(fn ->
        refute Bonfire.Social.FeedLoader.feed_contains?(:my, text, current_user: bob_remote)
      end)
    end

    test "outgoing to allowlisted domain is delivered", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      allowlist_remote_instance(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} =
          AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)

        Follows.follow(bob_remote, alice_on_remote)
      end)

      text = "archipelago allowlisted domain outgoing #{System.unique_integer()}"

      {:ok, _post} =
        Posts.publish(
          current_user: alice_local,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      TestInstanceRepo.apply(fn ->
        assert Bonfire.Social.FeedLoader.feed_contains?(:my, text, current_user: bob_remote)
      end)
    end

    test "block overrides domain allowlist — allowlisted domain + silenced actor = rejected",
         context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      allowlist_remote_instance(context)

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      assert {:ok, _} = Follows.follow(alice_local, bob_remote_on_local)

      assert {:ok, _} =
               Blocks.block(bob_remote_on_local, :silence, current_user: alice_local)

      text = "archipelago block-overrides-allowlist #{System.unique_integer()}"

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
  # allowlist affects follows
  # -----------------------------------------------------------------------

  describe "allowlist affects follows" do
    test "incoming follow from non-allowlisted domain is rejected", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        Follows.follow(bob_remote, alice_on_remote)
      end)

      refute Follows.following?(bob_remote_on_local, alice_local)
    end

    test "incoming follow from allowlisted domain is accepted", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      allowlist_remote_instance(context)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        Follows.follow(bob_remote, alice_on_remote)
      end)

      assert Follows.following?(bob_remote_on_local, alice_local)
    end

    test "outgoing follow to non-allowlisted domain is not delivered", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      Follows.follow(alice_local, bob_remote_on_local)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        refute Follows.following?(alice_on_remote, bob_remote)
      end)
    end

    test "outgoing follow to allowlisted domain is delivered", context do
      clean_slate(context)
      Federation.set_allowlist_only(:instance, true)
      allowlist_remote_instance(context)

      alice_local = context[:local][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote = context[:remote][:user]
      bob_remote_on_local = get_remote_on_local(context)

      Follows.follow(alice_local, bob_remote_on_local)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_by_url_ap_id_or_username(alice_local_ap_id)
        assert Follows.following?(alice_on_remote, bob_remote)
      end)
    end

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
