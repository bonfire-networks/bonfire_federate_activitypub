defmodule Bonfire.Federate.ActivityPub.Dance.ArchipelagoInstanceDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub, as: Federation
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks

  setup context do
    on_exit(fn ->
      clean_slate(context)
    end)
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

      refute Bonfire.Social.FeedLoader.feed_contains?(:remote, text, current_user: alice_local)
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

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, text, current_user: alice_local)
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
        refute Bonfire.Social.FeedLoader.feed_contains?(:remote, text, current_user: bob_remote)
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
        assert Bonfire.Social.FeedLoader.feed_contains?(:remote, text, current_user: bob_remote)
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

      refute Bonfire.Social.FeedLoader.feed_contains?(:remote, text, current_user: alice_local)
    end
  end

  # -----------------------------------------------------------------------
  # allowlist affects follows (instance-level)
  # -----------------------------------------------------------------------

  describe "allowlist affects follows (instance-level)" do
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
  end
end
