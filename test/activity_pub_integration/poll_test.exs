defmodule Bonfire.Federate.ActivityPub.PollTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Poll.Votes
  alias Bonfire.Federate.ActivityPub.Outgoing

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{
        method: :get,
        url: "https://mocked.local/.well-known/nodeinfo"
      } ->
        %Tesla.Env{status: 404, body: ""}

      # %{url: "https://mocked.local/relation/27005"} ->

      # NOTE: already mocked in AP lib

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "Question is recorded as poll question if bonfire_poll extension is enabled, otherwise as APActivity" do
    data =
      "../fixtures/poll_attachment.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(data)

    assert {:ok, activity} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
             |> repo().maybe_preload(choices: [:post_content])

    #  fallback if bonfire_poll is not enabled
    if Code.ensure_loaded?(Bonfire.Poll) do
      assert %{
               voting_format: "single",
               proposal_dates: nil,
               voting_dates: [_ | _]
             } =
               activity
               |> debug("Question activity")

      assert e(activity, :choices, [])
             |> Enum.map(fn %{} = choice ->
               assert choice.post_content.name in ["a", "b", "c", "d", "e", "f"]
             end)
             |> Enum.count() == 6

      # Test Update activity
      updated_poll_json =
        data
        |> Map.put("name", "Updated poll name")
        |> Map.put("oneOf", [
          %{
            "type" => "Note",
            "name" => "updated a",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          },
          %{
            "type" => "Note",
            "name" => "updated b",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }
        ])

      update_activity = %{
        "type" => "Update",
        "actor" => data["actor"],
        "object" => updated_poll_json
      }

      {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(update_activity)

      assert {:ok, updated_poll} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(choices: [:post_content])

      assert updated_poll.post_content.name == "Updated poll name"
      updated_names = Enum.map(updated_poll.choices, & &1.post_content.name)
      assert updated_names == ["updated a", "updated b"]
    else
      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert is_list(activity.json["oneOf"])
      assert activity.json["type"] == "Question"
      assert is_binary(activity.json["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)

      # Second fetch of the same data
      assert {:ok, activity2} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      # Should return the same activity, not create a duplicate
      assert activity.id == activity2.id
      assert activity.json["id"] == activity2.json["id"]
    end
  end

  describe "votes" do
    test "incoming vote (Create of a Note with name + inReplyTo) is recorded as a Bonfire Vote" do
      author = fake_user!()

      {:ok, question} =
        Bonfire.Poll.Fake.fake_question_with_choices(
          %{},
          [%{name: "yay"}, %{name: "nay"}],
          current_user: author,
          boundary: "public"
        )

      choice =
        Enum.find(question.choices, &(e(&1, :post_content, :name, nil) == "yay")) ||
          raise "expected a 'yay' choice"

      question_url = Bonfire.Common.URIs.canonical_url(question, preload_if_needed: true)
      author_url = Bonfire.Common.URIs.canonical_url(author, preload_if_needed: true)
      remote_actor = "https://mocked.local/users/karen"

      # a Mastodon-style vote: Create of a Note whose name is the option, inReplyTo the question, addressed to the poll author
      # (see forks/activity_pub/test/fixtures/mastodon/mastodon-vote.json)
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => remote_actor,
        "id" => remote_actor <> "#votes/1/activity",
        "to" => author_url,
        "type" => "Create",
        "object" => %{
          "attributedTo" => remote_actor,
          "id" => remote_actor <> "#votes/1",
          "inReplyTo" => question_url,
          "name" => "yay",
          "to" => author_url,
          "type" => "Note"
        }
      }

      assert {:ok, _activity} = ActivityPub.Federator.Transformer.handle_incoming(data)

      # the vote was recorded against the right choice
      assert %{} = counts = Votes.counts_for_choices([id(question)])
      assert counts[id(choice)] == 1
    end

    test "outgoing vote on a remote poll federates a Create with the chosen option" do
      data =
        "../fixtures/poll_attachment.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, question} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(choices: [:post_content])

      choice =
        Enum.find(question.choices, &(e(&1, :post_content, :name, nil) == "b")) ||
          raise "expected a 'b' choice"

      me = fake_user!()

      assert {:ok, vote} = Votes.vote(me, question, [%{choice_id: id(choice)}])

      # the vote was federated (same pattern as like_integration_test)
      ap_activity = Outgoing.ap_activity!(vote)
      assert %ActivityPub.Object{} = ap_activity
      assert ap_activity.data["type"] == "Create"

      object = ActivityPub.Object.normalize(ap_activity, fetch: false)
      assert object.data["name"] == "b"
      assert object.data["inReplyTo"] == data["id"]

      # addressed to the poll author only (Mastodon semantics), not public
      assert data["actor"] in List.wrap(ap_activity.data["to"])

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "outgoing multi-choice vote federates one Create per chosen option" do
      fixture =
        "../fixtures/poll_attachment.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      # turn the fixture into a multiple-choice poll with a distinct id
      # (Mastodon sends only ONE of oneOf/anyOf, so drop oneOf rather than emptying it)
      data =
        fixture
        |> Map.put("anyOf", fixture["oneOf"])
        |> Map.delete("oneOf")
        |> Map.put("id", "https://patch.local/objects/poll_attachment_multi")

      {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, question} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(choices: [:post_content])

      assert question.voting_format == "multiple"

      [choice1, choice2] =
        Enum.filter(question.choices, &(e(&1, :post_content, :name, nil) in ["a", "c"]))

      me = fake_user!()

      assert {:ok, _vote} =
               Votes.vote(me, question, [%{choice_id: id(choice1)}, %{choice_id: id(choice2)}])

      # one Create/Answer AP object per chosen option, each linked to its choice-vote pointer
      names =
        Enum.map([choice1, choice2], fn choice ->
          assert {:ok, choice_vote} = Votes.get(me, choice)

          assert {:ok, ap_object} = ActivityPub.Object.get_cached(pointer: id(choice_vote))
          assert ap_object.data["inReplyTo"] == data["id"]
          ap_object.data["name"]
        end)

      assert Enum.sort(names) == ["a", "c"]
    end
  end
end
