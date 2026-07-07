defmodule Bonfire.Federate.ActivityPub.ArchipelagoUserIngestTest do
  @moduledoc """
  Single-instance mirrors of the allow-path assertions in `test/dance/archipelago_user_dance_test.exs` (#2088). Same semantics — a user in `:allowlist_only` mode receiving a private Note (→ `Message`) from a remote actor — but pushed through `ActivityPub.create` + `Incoming.receive_activity/1` with mocked actor fetches instead of real two-instance delivery (idiom borrowed from `activity_pub_integration/message_integration_test.exs`).

  Diagnostic intent: if the allow-path tests here are RED, the per-user allowlist over-block is reachable in the ingest pipeline itself (fast to iterate on). If they are GREEN while the dance equivalents stay red, the bug lives in real delivery (HTTP signatures / actor resolution / Peered state differences between instances).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias ActivityPub.Actor
  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub.Peered
  alias Bonfire.Boundaries.Allowlist
  alias Bonfire.Messages

  @remote_actor "https://mocked.local/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    Process.put(:federating, true)
    alice = fake_user!("alice")
    # fetch the remote actor while alice is still in open mode, so the Peered record
    # exists before allowlisting (same ordering as the dance tests: contact known first)
    {:ok, _} = Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, peered} = Peered.get_by_uri(@remote_actor)
    [alice: alice, peered: peered]
  end

  defp set_allowlist_only(user) do
    current_user(
      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: user
      )
    )
  end

  # a private Note with a Mention of the recipient → becomes a Message on ingest
  defp ingest_remote_dm_to(user, text) do
    {:ok, actor} = Actor.get_cached_or_fetch(ap_id: @remote_actor)
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: user.id)

    params = remote_activity_json_with_mentions(actor, recipient_actor, %{"content" => text})

    with {:ok, activity} <- ActivityPub.create(params) do
      Incoming.receive_activity(activity)
    end
  end

  defp received_message?(user, text) do
    case Messages.list(user) do
      %{edges: edges} ->
        Enum.any?(
          edges,
          &String.contains?(e(&1, :activity, :object, :post_content, :html_body, nil) || "", text)
        )

      _ ->
        false
    end
  end

  test "control: remote DM arrives when the user is in open mode (harness sanity)",
       %{alice: alice} do
    text = "ingest control open mode #{System.unique_integer()}"
    assert {:ok, %Bonfire.Data.Social.Message{}} = ingest_remote_dm_to(alice, text)
    assert received_message?(alice, text)
  end

  # FIXME (#2088): currently RED — the DM from a non-allowlisted actor IS received. The per-user
  # allowlist deny is only enforced in the MRF at the delivery boundary; this ingest path
  # (`ActivityPub.create` + `Incoming.receive_activity`, the same approximation used by
  # message_integration_test.exs) skips inbound MRF, and nothing later in Bonfire's processing
  # re-checks the allowlist. Anything that enters by another door (relays, forwarded objects,
  # thread backfill / remote-reply fetching) lands regardless of allowlist-only mode.
  @tag :todo
  test "deny path: DM from non-allowlisted actor does not arrive", %{alice: alice} do
    alice = set_allowlist_only(alice)
    text = "ingest deny non-allowlisted #{System.unique_integer()}"

    # TEMP diagnostics: compare direct MRF filtering vs what happens inside create
    {:ok, actor} = Actor.get_cached_or_fetch(ap_id: @remote_actor)
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: alice.id)
    params = remote_activity_json_with_mentions(actor, recipient_actor, %{"content" => text})

    # (a) raw atom-keyed params, as the MRF unit tests feed it — expect alice trimmed/rejected
    IO.inspect(Bonfire.Federate.ActivityPub.BoundariesMRF.filter(params, false),
      label: "DIAG direct MRF on raw params"
    )

    # (b) approximation of the normalized string-keyed create_data shape that Object.insert filters
    string_keyed = %{
      "type" => "Create",
      "actor" => params.actor.data["id"],
      "to" => params.to,
      "context" => params.context,
      "object" => params.object
    }

    IO.inspect(Bonfire.Federate.ActivityPub.BoundariesMRF.filter(string_keyed, false),
      label: "DIAG direct MRF on string-keyed create_data"
    )

    create_result = ActivityPub.create(params)

    with {:ok, activity} <- create_result do
      IO.inspect(activity.data["to"], label: "DIAG activity.to after create")
      IO.inspect(Incoming.receive_activity(activity) |> elem(0), label: "DIAG receive result tag")
    else
      other -> IO.inspect(other, label: "DIAG create rejected")
    end

    refute received_message?(alice, text)
  end

  test "allow path (actor): DM from user-allowlisted actor arrives (mirrors dance test at :59)",
       %{alice: alice, peered: peered} do
    assert {:ok, _} = Allowlist.allow(peered, current_user: alice)
    alice = set_allowlist_only(alice)
    text = "ingest allow actor #{System.unique_integer()}"
    assert {:ok, %Bonfire.Data.Social.Message{}} = ingest_remote_dm_to(alice, text)
    assert received_message?(alice, text)
  end

  test "allow path (domain): DM from actor on user-allowlisted instance arrives (mirrors dance test at :91)",
       %{alice: alice} do
    {:ok, instance_circle} = Instances.get_or_create_instance_circle("mocked.local")
    assert {:ok, _} = Allowlist.allow(instance_circle, alice)
    alice = set_allowlist_only(alice)
    text = "ingest allow domain #{System.unique_integer()}"
    assert {:ok, %Bonfire.Data.Social.Message{}} = ingest_remote_dm_to(alice, text)
    assert received_message?(alice, text)
  end
end
