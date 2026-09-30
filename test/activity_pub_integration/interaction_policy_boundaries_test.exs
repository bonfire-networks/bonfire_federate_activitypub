defmodule Bonfire.Federate.ActivityPub.InteractionPolicyBoundariesTest do
  @moduledoc """
  What an incoming object's `interactionPolicy` (GoToSocial, Mastodon) lets local users do with it, per policy verb (`canLike`, `canAnnounce`, `canReply`, `canQuote`), the same for public and private objects. Only what changes someone's permissions is added, so the object's own boundary isn't repeated:

  1. no policy for a verb: the object's own boundary decides;
  2. `automaticApproval` lists a circle (Public, the author's followers, who the author follows): that verb, and only that verb, for the circle, so never reading; nothing when the boundary already gives it;
  3. only the author listed, with nobody else under `manualApproval`: that verb is denied to local users, on a private object its recipients included, as the author asked; nothing when the boundary doesn't give it anyway;
  4. only the author listed, others under `manualApproval`: whaterver is default for the object's boundaries (quoting and following will send requests, as other activities may be attempted and accepted/rejected by the remote author).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation
  import Tesla.Mock

  alias Bonfire.Boundaries

  # the remote actor the other ingest tests mock (`post_web_test.exs`)
  @actor "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @followers "#{@actor}/followers"
  @following "#{@actor}/following"
  @author_only %{"automaticApproval" => [@actor]}

  # policy key => the verb it's about
  @verbs %{
    "canLike" => :like,
    "canAnnounce" => :boost,
    "canReply" => :reply,
    "canQuote" => :quote
  }
  # what the object's own boundary gives without any policy (rule 1): a public object to local users; a private one, which arrives as a direct message, to its recipients (the `:message` verbs, without boosting)
  @given_by_boundary %{public: [:like, :boost, :reply], private: [:like, :reply]}

  setup_all do
    mock_global(fn
      %{method: :get, url: @actor} ->
        json(
          Simulate.actor_json(@actor)
          |> Map.merge(%{"followers" => @followers, "following" => @following})
        )

      %{method: :get, url: @followers} ->
        json(%{})

      %{method: :get, url: @following} ->
        json(%{})

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  # an incoming `Create{Note}` addressed to `to`, with `policy` as its `interactionPolicy` (none when nil)
  defp receive_note(to, policy) do
    id = "#{@actor}/notes/#{Needle.UID.generate()}"

    note =
      %{
        "type" => "Note",
        "id" => id,
        "attributedTo" => @actor,
        "content" => "a note",
        "to" => List.wrap(to),
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> then(&if(policy, do: Map.put(&1, "interactionPolicy", policy), else: &1))

    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "id" => "#{id}/activity",
        "actor" => @actor,
        "to" => List.wrap(to),
        "object" => note
      })

    {:ok, object} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    object
  end

  defp ap_id(user), do: Bonfire.Me.Characters.character_url(user)

  # the grants on an object, as {subject, verb, value}, so two objects with the same audience compare equal whatever their ACL ids
  defp grants_on(object) do
    import Ecto.Query
    acl_ids = object |> Bonfire.Boundaries.Controlleds.list_on_object() |> Enum.map(& &1.acl_id)

    from(g in Bonfire.Data.AccessControl.Grant,
      where: g.acl_id in ^acl_ids,
      select: {g.subject_id, g.verb_id, g.value}
    )
    |> Bonfire.Common.Repo.all()
    |> MapSet.new()
  end

  defp remote_author do
    {:ok, author} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@actor)

    author
  end

  # an object either for everyone (public) or for one recipient (private), and who to check each verb as
  defp audience(:public), do: {@public, fake_user!()}

  defp audience(:private) do
    recipient = fake_user!()
    {ap_id(recipient), recipient}
  end

  for kind <- [:public, :private] do
    @kind kind

    describe "#{kind}, 1. no policy" do
      test "its boundary decides" do
        {to, who} = audience(@kind)
        note = receive_note(to, nil)

        for verb <- Map.values(@verbs),
            do:
              assert(
                Boundaries.can?(who, verb, note) == verb in @given_by_boundary[@kind],
                "#{verb} as by default"
              )

        if @kind == :private,
          do: refute(Boundaries.can?(fake_user!(), :read, note), "others can't read it")
      end
    end

    for {policy_key, verb} <- @verbs do
      @policy_key policy_key
      @verb verb

      describe "#{kind}, #{policy_key}" do
        test "2. approved for everyone: #{verb} is allowed" do
          {to, who} = audience(@kind)
          note = receive_note(to, %{@policy_key => %{"automaticApproval" => [@public]}})
          assert Boundaries.can?(who, @verb, note)

          if @kind == :private,
            do:
              refute(
                Boundaries.can?(fake_user!(), :read, note),
                "the grant doesn't open it to others"
              )
        end

        if verb in @given_by_boundary[kind] do
          test "2. approved for everyone, when the boundary already gives #{verb}: nothing is added" do
            {to, _who} = audience(@kind)

            assert grants_on(
                     receive_note(to, %{@policy_key => %{"automaticApproval" => [@public]}})
                   ) ==
                     grants_on(receive_note(to, nil))
          end
        end

        test "3. only its author, nobody else even with approval: #{verb} is denied, and nothing else" do
          {to, who} = audience(@kind)
          note = receive_note(to, %{@policy_key => @author_only})
          refute Boundaries.can?(who, @verb, note), "#{@verb} is denied"

          for other <- @given_by_boundary[@kind] -- [@verb],
              do: assert(Boundaries.can?(who, other, note), "#{other} isn't")
        end

        if verb not in @given_by_boundary[kind] do
          test "3. only its author, when the boundary doesn't give #{verb} anyway: nothing is added" do
            {to, _who} = audience(@kind)

            assert grants_on(receive_note(to, %{@policy_key => @author_only})) ==
                     grants_on(receive_note(to, nil))
          end
        end

        test "4. only its author, others may ask: nothing extra is applied, #{verb} is as by default" do
          {to, who} = audience(@kind)

          policy_note =
            receive_note(to, %{@policy_key => Map.put(@author_only, "manualApproval", [@public])})

          assert Boundaries.can?(who, @verb, policy_note) == @verb in @given_by_boundary[@kind]
          assert grants_on(policy_note) == grants_on(receive_note(to, nil)), "nothing is added"
        end
      end
    end
  end

  describe "approved for the author's followers, or who they follow" do
    test "a follower of the author may quote a public note approved for followers, and someone else may not" do
      follower = fake_user!()
      author = remote_author()

      # following a remote actor is a request until it sends an `Accept` (as in `follow_integration_test.exs`)
      {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower, author)
      {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)
      {:ok, ap_follower} = ActivityPub.Federator.Adapter.get_actor_by_id(follower.id)
      {:ok, ap_author} = ActivityPub.Actor.get_cached(ap_id: @actor)

      {:ok, accept} =
        ActivityPub.accept(%{
          actor: ap_author,
          to: [ap_follower.data],
          object: follow_activity.data,
          local: false
        })

      {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)

      assert Bonfire.Social.Graph.Follows.following?(follower, author),
             "control: the follow took effect"

      note = receive_note(@public, %{"canQuote" => %{"automaticApproval" => [@followers]}})
      assert Boundaries.can?(follower, :quote, note), "a follower may"
      refute Boundaries.can?(fake_user!(), :quote, note), "someone else may not"
    end

    test "someone the author follows may quote a public note approved for them, and someone else may not" do
      followed = fake_user!()

      {:ok, _} =
        Bonfire.Social.Graph.Follows.follow(remote_author(), followed, skip_boundary_check: true)

      note = receive_note(@public, %{"canQuote" => %{"automaticApproval" => [@following]}})
      assert Boundaries.can?(followed, :quote, note), "someone they follow may"
      refute Boundaries.can?(fake_user!(), :quote, note), "someone else may not"
    end
  end
end
