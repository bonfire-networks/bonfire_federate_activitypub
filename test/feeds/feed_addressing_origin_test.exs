defmodule Bonfire.Federate.ActivityPub.FeedAddressingOriginTest do
  @moduledoc """
  Origin-aware feed addressing (local-remote-feeds Phase 1B follow-up). Under `feed_addressing`, a
  CUSTOM-boundary activity routes to `local_custom` for a LOCAL author but `remote_custom` for a
  REMOTE author (a remote non-public ingest gets a custom boundary too; the fetcher service character
  also classifies as remote). Lives here because it needs the remote-author fixture + AP mocks.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Social.Feeds
  alias Bonfire.Me.Fake

  alias Bonfire.Posts
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Social.Boosts

  import Bonfire.Federate.ActivityPub

  @local_public "7PVB11C0BJECTFR0M10CA1VSER"
  @local_instance_only "710CA10BJ0N1YF0R10CA1VSERS"
  @local_custom "3SERSFR0MY0VR10CA11NSTANCE"
  @remote_public "7PVB11C0BJFR0MAREM0TEACT0R"
  @remote_custom "7EDERATEDW1THANACT1V1TYPVB"

  @remote_actor "https://mocked.local/users/karen"

  setup do
    mock(fn %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor)) end)
  end

  test "custom-boundary content routes to remote_custom for a remote author, local_custom for a local author" do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

    local = Fake.fake_user!()
    {:ok, remote} = Simulate.fake_remote_user(@remote_actor)

    local_feeds = Feeds.fan_out_feed_ids(local, "mentions")
    remote_feeds = Feeds.fan_out_feed_ids(remote, "mentions")

    assert @local_custom in local_feeds, "local author's custom content → local_custom"
    assert @remote_custom in remote_feeds, "remote author's custom content → remote_custom"

    refute @local_custom in remote_feeds,
           "remote author's custom content must NOT land in local_custom"
  end

  test "with `addressing_origin_by: :object` config: classifies by the object's locality instead of the subject's" do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

    local = Fake.fake_user!()
    {:ok, remote} = Simulate.fake_remote_user(@remote_actor)

    # :subject policy (explicit): classify by the local subject → local_custom, even with a remote object
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :addressing_origin_by], :subject)
    subject_feeds = Feeds.fan_out_feed_ids(local, "mentions", [], nil, nil, object: remote)
    assert @local_custom in subject_feeds, "with :subject, a local subject routes to local_custom"

    refute @remote_custom in subject_feeds,
           "with :subject, a remote object must NOT force remote_custom"

    # :object policy: classify by the (remote) object instead → remote_custom
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :addressing_origin_by], :object)
    feeds = Feeds.fan_out_feed_ids(local, "mentions", [], nil, nil, object: remote)

    assert @remote_custom in feeds, "with :object, a remote object routes to remote_custom"
    refute @local_custom in feeds, "with :object, a local subject must NOT force local_custom"

    # opposite: remote subject + local object, :object → local_custom
    local_object = Fake.fake_user!()
    feeds2 = Feeds.fan_out_feed_ids(remote, "mentions", [], nil, nil, object: local_object)

    assert @local_custom in feeds2,
           "with :object, a local object routes to local_custom (remote subject)"

    refute @remote_custom in feeds2, "with :object, a remote subject must NOT force remote_custom"
  end

  test "the fetcher/service actor's content routes to remote buckets (so :local needs no subject!=fetcher guard)" do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

    # the service/fetcher character (fetches remote content) — is_local? treats it as remote
    fetcher = %{id: Bonfire.Federate.ActivityPub.AdapterUtils.service_character_id()}

    feeds = Feeds.fan_out_feed_ids(fetcher, "mentions")

    assert @remote_custom in feeds, "fetcher/service actor classified as remote → remote_custom"
    refute @local_custom in feeds, "fetcher content must NOT land in local buckets"
  end

  # :todo — boosts don't currently get an origin bucket row: `Edges.insert` publishes only to the explicit `to_feeds` (booster outbox + creator notification), bypassing `global_feed_ids`. So this asserts behavior that doesn't exist yet. Parked until we decide whether boosts should appear in `:local`/`:remote` origin feeds under addressing (see local-remote-feeds plan). Run with `--include todo`.
  @tag :todo
  test "with feed_addressing on, a received (remote) boost of a local post is addressed to remote buckets" do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

    user = fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "content"}},
        boundary: "public"
      )

    {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    {:ok, actor} =
      ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://mocked.local/users/karen")

    {:ok, ap_boost} = ActivityPub.announce(%{actor: actor, object: ap_activity.object})

    {:ok, %Boost{} = boost_pointer} =
      Bonfire.Federate.ActivityPub.Incoming.receive_activity(ap_boost)

    boost_feeds = Bonfire.Social.FeedActivities.feeds_for_activity(id(boost_pointer.activity))

    # the boost's subject is the remote actor → remote buckets, never local
    assert Enum.any?(boost_feeds, &(&1 in [@remote_public, @remote_custom])),
           "remote boost is addressed to a remote bucket"

    refute Enum.any?(boost_feeds, &(&1 in [@local_public, @local_instance_only, @local_custom])),
           "remote boost must NOT land in local buckets"
  end
end
