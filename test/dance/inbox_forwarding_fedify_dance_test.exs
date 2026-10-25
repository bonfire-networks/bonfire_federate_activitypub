defmodule Bonfire.Federate.ActivityPub.Dance.InboxForwardingFedifyTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2) with three servers (`Testing.Scenarios.inbox_forwarding/2`), the follower being Fedify (an FEP-8b32 implementation): the Fedify CLI's ephemeral inbox (`fedify inbox`) follows our user, a user on the dance's other instance replies to our user's post, and we forward the reply to Fedify's inbox, which processes it on the replier's proof. Real servers' accounts run the same scenario in `live_federation/inbox_forwarding_live_test.exs`.

  Needs the `fedify` CLI on the `PATH`, and tunnels: Fedify refuses private addresses (`Disallowed private URL`), and `fedify inbox` has no option to allow them. So Fedify tunnels its own inbox, and both dance instances are tunnelled by the recipe; without the tunnels (`TUNNELED=yes`, which the recipe sets) it skips itself:

      just test-federation-dance-tunneled extensions/bonfire_federate_activitypub/test/dance/inbox_forwarding_fedify_dance_test.exs
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance
  @moduletag capture_log: false

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  setup context do
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  @tag :test_instance
  # ExUnit's own `skip:`, which still applies under `--only test_instance`
  if reason =
       Tester.skip_reason(Tester.FedifyTester, [:follow, :delivery_outcome]),
     do: @tag(skip: reason)

  @tag timeout: :timer.minutes(10)
  test "a reply from the other instance to our user's post is forwarded to Fedify, which accepts it on the replier's proof",
       context do
    Scenarios.inbox_forwarding(context, Tester.new(Tester.FedifyTester, context))
  end
end
