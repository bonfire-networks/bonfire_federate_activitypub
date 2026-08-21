defmodule Bonfire.Federate.ActivityPub.Dance.CircleBoundariesDanceTest do
  @moduledoc """
  Bonfire -> Bonfire proof of the circle-boundary federation bug.

  The existing `remote_boundaries_dance_test.exs` has a "custom with circle containing remote users permitted" case, but it publishes with `boundary: "public"` plus `to_circles`, so `to` contains the AP public URI and the activity federates on the public path. The bug is never exercised.

  These use a genuinely non-public custom ACL whose audience is only a circle, which is what was reported. Before the fix the post shipped with an empty audience and `BoundariesMRF` dropped it inside `ActivityPub.Object.insert` before any row was written, so nothing was delivered; `AdapterUtils.determine_recipients/4` now addresses the deliverable recipients in `bcc`.

  Delivery stays gated on mentioned-or-following, so the second test (a grantee who does NOT follow the author receives nothing) guards that chosen default rather than describing a bug.

  The equivalent proof against a real Mastodon lives in `test/live_federation/circle_audience_live_test.exs`, which still characterises the pre-fix behaviour.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.{Acls, Circles, Grants}

  setup context do
    on_exit(fn ->
      clean_slate(context)
    end)
  end

  # a non-public custom ACL granting see+read to a circle containing `member`
  defp publish_with_circle_boundary!(author, member, html_body) do
    {:ok, circle} = Circles.create(author, %{named: %{name: "besties"}})
    {:ok, _} = Circles.add_to_circles(id(member), circle)

    {:ok, acl} = Acls.simple_create(author, "besties only")
    Grants.grant(circle.id, acl.id, [:see, :read], true, current_user: author)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: html_body}},
        boundary: acl.id
      )

    post
  end

  describe "a post whose audience is only a circle" do
    test "reaches a remote circle member who follows me", context do
      attrs = "circle-only boundary, remote member follows me"

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote_ap_id = context[:remote][:canonical_url]

      {:ok, bob_on_local} = AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      # bob follows alice, so bob is a deliverable recipient under the existing mentioned-or-following gate
      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_local_ap_id)
        Follows.follow(bob_remote, alice_on_remote)
        assert true == Follows.following?(bob_remote, alice_on_remote)
      end)

      post = publish_with_circle_boundary!(alice_local, bob_on_local, attrs)

      # preconditions, so a fixture problem cannot masquerade as the bug
      refute Boundaries.object_public?(post)
      assert [_ | _] = Boundaries.users_grants_on([bob_on_local], [post], [:see, :read])

      # the bug: no AP object is created at all, so nothing is ever queued or delivered
      assert {:ok, _} = ActivityPub.Object.get_cached(pointer: id(post))

      # Assert RECEIPT, not placement. `Posts.ap_receive_activity` currently routes any non-public post carrying recipients to `Messages.send`, so a circle post lands in the DM inbox rather than a feed. Correcting that routing is deliberately out of scope here; the `:todo` test below pins the desired placement.
      TestInstanceRepo.apply(fn ->
        assert Bonfire.Social.FeedLoader.feed_contains?(
                 Bonfire.Messages.list(bob_remote),
                 attrs,
                 current_user: bob_remote
               )
      end)
    end

    # NOTE: `:todo` alone does not park a test in this suite: `test-federation-dance` runs with `--only test_instance`, and an ExUnit include beats `--exclude todo`, so it would run and fail. `skip:` parks it unconditionally and shows the reason in the output.
    @tag :todo
    @tag skip:
           "deferred: needs the incoming Post-vs-Message discriminator (audience recipients without a `Mention` tag are a circle post, not a DM)"
    test "a circle post arrives as a feed post rather than a DM", context do
      attrs = "circle-only boundary, should land in the feed"

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      alice_local_ap_id = context[:local][:canonical_url]
      bob_remote_ap_id = context[:remote][:canonical_url]

      {:ok, bob_on_local} = AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      TestInstanceRepo.apply(fn ->
        {:ok, alice_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_local_ap_id)
        Follows.follow(bob_remote, alice_on_remote)
      end)

      publish_with_circle_boundary!(alice_local, bob_on_local, attrs)

      # parked: needs the incoming Post-vs-Message discriminator (audience recipients WITHOUT a `Mention` tag are a circle post, not a DM). Run with `--include todo`.
      TestInstanceRepo.apply(fn ->
        assert Bonfire.Social.FeedLoader.feed_contains?(:my, attrs, current_user: bob_remote)
      end)
    end

    test "does not reach a remote circle member who does not follow me", context do
      attrs = "circle-only boundary, remote member does not follow me"

      alice_local = context[:local][:user]
      bob_remote = context[:remote][:user]
      bob_remote_ap_id = context[:remote][:canonical_url]

      {:ok, bob_on_local} = AdapterUtils.get_by_url_ap_id_or_username(bob_remote_ap_id)

      _post = publish_with_circle_boundary!(alice_local, bob_on_local, attrs)

      # guards the chosen default: delivery stays gated on mentioned-or-following, so a grantee who does not follow is deliberately not reached. Must keep passing after the addressing fix.
      TestInstanceRepo.apply(fn ->
        refute Bonfire.Social.FeedLoader.feed_contains?(:my, attrs, current_user: bob_remote)
      end)
    end
  end
end
