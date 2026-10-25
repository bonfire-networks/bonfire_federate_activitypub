defmodule Bonfire.Federate.ActivityPub.Dance.DeliveryTest do
  @moduledoc """
  A post delivered to a follower, us to them: the receiver follows our user (`follow`), our user posts (`Tester.NomadTester`), and the receiver says what it made of the delivery (`delivery_outcome`): `Testing.Scenarios.delivery/2`, run once for each receiver here. Real servers' accounts run the same scenario in `live_federation/delivery_live_test.exs`.

  Fedify follows only through `fedify inbox`, which needs both dance instances tunnelled, so its run skips itself without them:

      just test-federation-dance-tunneled extensions/bonfire_federate_activitypub/test/dance/delivery_test.exs
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  # every tester that can follow and say what it made of a delivery
  # the dance's remote user follows ours through its own instance's contexts, and through its GraphQL API over HTTP (where what it accepted is read on that instance too)
  @receivers [
    {Tester.NomadTester, {:dance_instance, :remote}},
    {Tester.NomadTester, {:graphql, :remote}},
    Tester.FedifyTester
  ]

  setup context do
    clean_slate(context)
  end

  for receiver <- @receivers do
    @tag :test_instance
    @tag receiver: receiver
    @tag timeout: :timer.minutes(10)
    # ExUnit's own `skip:`, which still applies under `--only test_instance`
    if reason = Tester.skip_reason(receiver, [:follow, :delivery_outcome]),
      do: @tag(skip: reason)

    test "#{inspect(receiver)}: a post delivered to a follower is accepted", context do
      Scenarios.delivery(context, Tester.new(context[:receiver], context))
    end
  end
end
