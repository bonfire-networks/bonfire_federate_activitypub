defmodule Bonfire.Federate.ActivityPub.Dance.PostsHashtagsTest do
  @moduledoc """
  A public post with hashtags (`Testing.Scenarios.posts_hashtags/3`), run for each pair of sender and receiver here, both ways: us to the dance's other instance and to Fedify's CLI, and the dance's other instance to us. Real servers' accounts run the same scenario in `live_federation/posts_hashtags_live_test.exs`.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  @us {Tester.NomadTester, :local}
  @dance_instance {Tester.NomadTester, {:dance_instance, :remote}}

  # who posts, and who finds and shows the post; the GraphQL ones post through our GraphQL API in process, and through the other instance's over HTTP
  @pairs [
    {@us, @dance_instance, "us to the dance's other instance"},
    {@us, Tester.FedifyTester, "us to Fedify"},
    {@dance_instance, @us, "the dance's other instance to us"},
    {{Tester.NomadTester, {:graphql, :local}}, @dance_instance,
     "us, through our GraphQL API, to the dance's other instance"},
    # disabled until the C2S plan is done (see `Nomad.C2S`): {{Tester.NomadTester, {:c2s, :remote}}, @us, "the dance's other instance, through its ActivityPub client-to-server outbox, to us"},
    {{Tester.NomadTester, {:graphql, :remote}}, @us,
     "the dance's other instance, through its GraphQL API over HTTP, to us"}
  ]

  for {sender, receiver, direction} <- @pairs do
    @tag :test_instance
    @tag sender: sender, receiver: receiver
    # ExUnit's own `skip:`, which still applies under `--only test_instance`
    if reason =
         Tester.skip_reason(sender, [:post, :uri_of]) ||
           Tester.skip_reason(receiver, [:resolve, :find_post]),
       do: @tag(skip: reason)

    test "#{direction}: finds a public post, and shows its text and hashtags", context do
      Scenarios.posts_hashtags(
        context,
        Tester.new(context[:sender], context),
        Tester.new(context[:receiver], context)
      )
    end
  end
end
