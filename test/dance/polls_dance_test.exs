defmodule Bonfire.Federate.ActivityPub.Dance.PollTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Fake
  alias Bonfire.Social.Graph.Follows

  @tag :test_instance
  test "poll dances and results match on both instances", context do
    local_user = context[:local][:user]

    remote_user = context[:remote][:user]

    local_ap_id = Bonfire.Me.Characters.character_url(local_user)

    # 1. Remote user follows local user to enable federation
    TestInstanceRepo.apply(fn ->
      assert {:ok, local_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      {:ok, _follow} = Follows.follow(remote_user, local_on_remote)
    end)

    # 2. Create poll on local with multiple choices
    choices = [
      %{name: "Option A"},
      %{name: "Option B", summary: "Second option"},
      %{name: "Option C", html_body: "Third option"}
    ]

    {:ok, poll} =
      Fake.fake_question_with_choices(
        %{
          voting_format: "multiple",
          voting_dates: [DateTime.utc_now(), DateTime.add(DateTime.utc_now(), 3600, :second)]
        },
        choices,
        current_user: local_user
      )
      |> debug("Created poll")

    poll = repo().maybe_preload(poll, choices: [:post_content])

    poll_url = URIs.canonical_url(poll) |> debug("Poll URL")

    # 3. Get poll on remote (should be federated inline)
    remote_results =
      TestInstanceRepo.apply(fn ->
        {:ok, remote_poll} =
          Bonfire.Poll.Questions.get_by_uri(poll_url, current_user: remote_user)
          |> repo().maybe_preload(choices: [:post_content])
          |> debug("Remote fetched poll")

        # 4. Vote on remote for two choices
        remote_choices =
          remote_poll.choices
          |> debug("Remote poll choices")

        vote_input =
          remote_choices
          |> Enum.take(2)
          |> Enum.map(fn %{id: id} ->
            %{choice_id: id, weight: 1}
          end)

        {:ok, _vote_activity} =
          Votes.vote(remote_user, remote_poll, vote_input)
          |> debug("Remote user voted")

        remote_results =
          Enum.map(remote_choices, fn choice ->
            Votes.calculate_if_visible(choice, remote_poll, current_user: remote_user)
          end)
          |> debug("Remote results")
      end)

    # 5. Results should be federated inline, compare results
    {:ok, poll} = Questions.read(poll.id, current_user: local_user)
    local_choices = poll.choices

    local_results =
      Enum.map(local_choices, fn choice ->
        Votes.calculate_if_visible(choice, poll, current_user: local_user)
      end)

    assert local_results == remote_results
  end
end
