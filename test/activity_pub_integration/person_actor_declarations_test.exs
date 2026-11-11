defmodule Bonfire.Federate.ActivityPub.PersonActorDeclarationsTest do
  @moduledoc """
  What our own Person actor declares about being followed.

  `manuallyApprovesFollowers` is the AS2 field Mastodon reads (and everything that copies Mastodon) to show a follow as PENDING rather than accepted. Bonfire accounts can require approval (`request_before_follow` puts a `:no_follow` boundary in place at signup, per user or instance-wide via `Config.get([Bonfire.Me.Users, :request_before_follow])`), and an account that reviews follows declares it, so the remote holds the follow as pending rather than offering a plain Follow button and waiting on an `Accept` that only a human decision can produce. Stated either way rather than omitted, since an absent flag reads as unknown rather than as open.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Graph.Follows

  defp actor_data(user) do
    assert %{data: data} = AdapterUtils.format_actor(user)
    data
  end

  test "a user who reviews follows says so" do
    user = fake_user!(%{}, %{}, request_before_follow: true)

    assert actor_data(user)["manuallyApprovesFollowers"] == true,
           "this is the only thing a remote reads before deciding whether to show the follow as pending"
  end

  test "a user anyone may follow says that too" do
    user = fake_user!()

    assert actor_data(user)["manuallyApprovesFollowers"] == false
  end

  # The invariant worth pinning, since the declaration and the enforcement are separate code: what we advertise has to be what a follow actually meets. Both branches are exercised, because an assertion that only ever sees the locked case would equally pass on a field hardcoded to `true`.
  test "the declaration matches what a follow actually does" do
    for request_before_follow <- [true, false] do
      followed = fake_user!(%{}, %{}, request_before_follow: request_before_follow)
      follower = fake_user!()

      assert {:ok, _} = Follows.follow(follower, followed)

      assert actor_data(followed)["manuallyApprovesFollowers"] ==
               Follows.requested?(follower, followed),
             "a follow of this account is #{if request_before_follow, do: "held for approval", else: "accepted immediately"}, so the actor must say exactly that"
    end
  end

  describe "a remote person's own declaration" do
    import Tesla.Mock

    alias ActivityPub.Federator.Transformer
    alias Bonfire.Boundaries.Queries
    alias Bonfire.Federate.ActivityPub.Adapter
    alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

    @remote "https://mastodon.local/users/lockable"
    @public "https://www.w3.org/ns/activitystreams#Public"

    defp remote_doc(overrides), do: APSimulate.actor_json(@remote, "lockable", overrides)

    defp origin_serves(doc) do
      mock(fn
        %{method: :get, url: @remote} -> json(doc)
        %{method: :post} -> %Tesla.Env{status: 202, body: ""}
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)
    end

    defp create_remote!(doc) do
      origin_serves(doc)
      assert {:ok, remote} = Adapter.maybe_create_remote_actor(doc)
      remote
    end

    # signed by the actor itself, so the embedded document is applied as sent
    defp receive_update!(doc) do
      assert {:ok, _} =
               Transformer.handle_incoming(
                 %{
                   "type" => "Update",
                   "id" => "#{@remote}#updates/#{Faker.random_between(1, 1_000_000)}",
                   "actor" => @remote,
                   "object" => doc,
                   "to" => [@public]
                 },
                 authenticated: :http_signature,
                 signed_by: @remote
               )

      assert {:ok, remote} = Bonfire.Me.Users.by_ap_id(@remote)
      remote
    end

    defp verbs(follower, remote),
      do: Queries.permitted_verbs_on(follower, remote, [:follow, :request])

    defp assert_followable(follower, remote, msg) do
      assert :follow in verbs(follower, remote), msg
      assert Bonfire.Boundaries.can?(follower, :follow, remote), msg
    end

    defp assert_ask_only(follower, remote, msg) do
      assert :request in verbs(follower, remote), "control: they may still ask. #{msg}"
      refute :follow in verbs(follower, remote), msg
      refute Bonfire.Boundaries.can?(follower, :follow, remote), msg
    end

    test "manuallyApprovesFollowers decides whether we may follow outright or only ask" do
      follower = fake_user!()

      locked = create_remote!(remote_doc(%{"manuallyApprovesFollowers" => true}))

      assert_ask_only(
        follower,
        locked,
        "a remote account that reviews followers must only be asked"
      )

      # control, with the setting that applies to our own signups switched on: a remote person follows their own declaration
      Process.put([:bonfire_me, Bonfire.Me.Users, :request_before_follow], true)

      open_doc =
        APSimulate.actor_json("https://mastodon.local/users/open", "open", %{
          "manuallyApprovesFollowers" => false
        })

      mock(fn
        %{method: :get, url: "https://mastodon.local/users/open"} -> json(open_doc)
        %{method: :post} -> %Tesla.Env{status: 202, body: ""}
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, open} = Adapter.maybe_create_remote_actor(open_doc)

      assert_followable(
        follower,
        open,
        "a remote account that does not review followers may be followed outright"
      )
    end

    test "an Update flips it both ways, and a document without the flag is followable" do
      follower = fake_user!()

      remote = create_remote!(remote_doc(%{"manuallyApprovesFollowers" => false}))
      assert_followable(follower, remote, "control: created open")

      remote = receive_update!(remote_doc(%{"manuallyApprovesFollowers" => true}))

      assert_ask_only(
        follower,
        remote,
        "an account that starts reviewing followers must stop being followable outright"
      )

      remote = receive_update!(remote_doc(%{"manuallyApprovesFollowers" => false}))

      assert_followable(
        follower,
        remote,
        "an account that stops reviewing followers must be followable again"
      )

      receive_update!(remote_doc(%{"manuallyApprovesFollowers" => true}))

      remote = receive_update!(Map.delete(remote_doc(%{}), "manuallyApprovesFollowers"))

      assert_followable(
        follower,
        remote,
        "an account that no longer declares it is followable, as for a group"
      )
    end

    test "an update with no declarations leaves a locked account locked" do
      follower = fake_user!()
      remote = create_remote!(remote_doc(%{"manuallyApprovesFollowers" => true}))

      assert {:ok, remote} = Bonfire.Me.Users.update_remote_actor(remote, %{"profile" => %{}})

      assert_ask_only(
        follower,
        remote,
        "a change with nothing said about followers must not reset them"
      )
    end

    test "following a locked remote account is a request that waits for its Accept" do
      follower = fake_user!()
      remote = create_remote!(remote_doc(%{"manuallyApprovesFollowers" => true}))

      assert {:ok, %Bonfire.Data.Social.Request{}} = Follows.follow(follower, remote)
      assert Follows.requested?(follower, remote)
      refute Follows.following?(follower, remote)
    end
  end
end
