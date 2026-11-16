defmodule Bonfire.Federate.ActivityPub.MRF.InstanceBlockInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"

  setup do
    Process.put(:federating, true)
    :ok
  end

  setup_all do
    orig = Config.get!(:boundaries)

    # local_user = fake_user!(@local_actor)

    Config.put(:boundaries,
      block: [],
      silence_them: [],
      ghost_them: []
    )

    # TODO: move this into fixtures
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end

  describe "do not block when" do
    test "there's no blocks (in config)" do
      Config.put([:boundaries, :block], [])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote actor" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's no matching local activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "block when" do
    test "attempting to follow from an instance-wide blocked instance" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:total, scope: :instance_wide, skip_boundary_check: true)

      refute match?(
               {:ok, follow_activity},
               ActivityPub.follow(%{actor: remote_actor, object: local_actor, local: false})
             )

      # refute match? {:ok, _}, Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Graph.Follows.following?(remote_user, local_user)
    end

    test "attempting to follow someone on an instance-wide blocked instance" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:total, scope: :instance_wide, skip_boundary_check: true)

      refute match?(
               {:ok, follow_activity},
               ActivityPub.follow(%{actor: local_actor, object: remote_actor, local: true})
             )

      # refute match? {:ok, _}, Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Graph.Follows.following?(local_user, remote_user)
    end

    test "there's a remote activity with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote activity with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      # |> debug
      ~> Bonfire.Boundaries.Blocks.block(:block, scope: :instance_wide, skip_boundary_check: true)

      # |> debug

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote activity with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*mocked.local"])

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote actor with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, scope: :instance_wide, skip_boundary_check: true)

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked host" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end
  end

  describe "block when recipients filtered because" do
    test "there's a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, scope: :instance_wide, skip_boundary_check: true)

      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked domain as recipient" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end

  # An instance-wide block of a host refuses what its actors send of any kind, not only their posts: a like, as much as a post, is taken from nobody on a blocked host, whether they send it themselves or a relay hands it to us wrapped in an `Announce`.
  describe "block other activities from a blocked host" do
    alias ActivityPub.Federator.Worker.ReceiverHelpers
    alias Bonfire.Social.Likes

    @blocked_host "blocked.local"
    @blocked_actor "https://blocked.local/users/bob"
    @relay_actor "https://relay.local/users/relay"
    @public "https://www.w3.org/ns/activitystreams#Public"

    setup do
      mock(fn
        %{method: :get, url: @blocked_actor} ->
          json(Simulate.actor_json(@blocked_actor, "bob"))

        %{method: :get, url: @relay_actor} ->
          json(Simulate.actor_json(@relay_actor, "relay"))

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}
      end)

      # both are known before the block is made, as the actors of a host that is blocked later
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @blocked_actor)
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @relay_actor)
      {:ok, blocked_user} = Bonfire.Me.Users.by_ap_id(@blocked_actor)

      author = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "a post that is liked from far away"}},
          boundary: "public"
        )

      %{
        blocked_user: blocked_user,
        post: post,
        post_url: Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true),
        author_url: Bonfire.Common.URIs.canonical_url(author)
      }
    end

    # a like of the post, addressed to its author only (as a like is by Mastodon), not to the public
    defp like_doc(ctx) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://blocked.local/likes/#{System.unique_integer([:positive])}",
        "type" => "Like",
        "actor" => @blocked_actor,
        "to" => [ctx.author_url],
        "object" => ctx.post_url
      }
    end

    # handed to the receiver worker as the inbox does once the signature of `signer` held
    defp receive_signed(signer, doc) do
      ReceiverHelpers.perform(
        %Oban.Job{
          args: %{
            "op" => "incoming_ap_doc",
            "params" => doc,
            "signed_by" => signer,
            "repo" => ActivityPub.Utils.repo()
          }
        },
        :verified
      )
    end

    test "control: a like from a host that is not blocked is taken", ctx do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      receive_signed(@blocked_actor, like_doc(ctx))

      assert Likes.liked?(ctx.blocked_user, ctx.post)
    end

    test "a like sent by an actor of a blocked host is refused", ctx do
      Config.put([:boundaries, :block], [@blocked_host])

      receive_signed(@blocked_actor, like_doc(ctx))

      refute Likes.liked?(ctx.blocked_user, ctx.post)
    end

    test "a post sent by an actor of a blocked host is refused", ctx do
      Config.put([:boundaries, :block], [@blocked_host])
      note_id = "https://blocked.local/notes/#{System.unique_integer([:positive])}"

      receive_signed(@blocked_actor, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => note_id <> "/activity",
        "type" => "Create",
        "actor" => @blocked_actor,
        "to" => [@public],
        "object" => %{
          "id" => note_id,
          "type" => "Note",
          "attributedTo" => @blocked_actor,
          "content" => "from a blocked host",
          "to" => [@public]
        }
      })

      refute match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: note_id))
    end
  end

  describe "filter recipients when" do
    test "there's a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor: local_activity.actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end

    test "there's a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, scope: :instance_wide, skip_boundary_check: true)

      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor: local_activity.actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end

    test "there's a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor: local_activity.actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end

    test "there's a local activity with instance-wide blocked domain as recipient" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor: local_activity.actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end
  end
end
