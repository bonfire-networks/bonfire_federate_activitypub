defmodule Bonfire.Federate.ActivityPub.Dance.InboxForwardingFedifyTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2) with three servers, the third being Fedify (an FEP-8b32 implementation): the Fedify CLI's ephemeral inbox (`fedify inbox`) follows our user, a user on the dance's other instance replies to our user's post, and we forward the reply to Fedify's inbox.

  The forward carries the replier's FEP-8b32 proof and our user's HTTP signature, which is not the reply's author's, so Fedify accepting it (a 2xx) means it relied on the proof.

  Needs the `fedify` CLI on the `PATH` (skipped otherwise), and tunnels: Fedify refuses private addresses (`Disallowed private URL`), and `fedify inbox` has no option to allow them (its document loader is made with none, unlike `fedify lookup -p`). So Fedify tunnels its own inbox, and both dance instances are tunnelled by the recipe (it needs no account of anyone's, so it is not one of the live recipes); without the tunnels (`TUNNELED=yes`, which the recipe sets) it skips itself:

      just test-federation-dance-tunneled extensions/bonfire_federate_activitypub/test/dance/inbox_forwarding_fedify_dance_test.exs
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false
  use Repatch.ExUnit

  @moduletag :test_instance
  @moduletag capture_log: false

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias ActivityPub.Federator.Forwarder
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  @fedify System.find_executable("fedify")
  @wait 120

  setup context do
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  # starts `fedify inbox` following `actor_uri`, and gives its actor and shared inbox URIs once it says them
  defp start_fedify_inbox(actor_uri) do
    port =
      Port.open({:spawn_executable, @fedify}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # `-d`: its debug log (lookups, what it sends, how it checks what it receives), which a failure message shows; tunnelled (no `-T`), as it refuses private addresses
        args: ["inbox", "-d", "-f", actor_uri, "-a", "*"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [to_string(os_pid)]) end)

    read_fedify(port, "", nil, nil)
  end

  defp read_fedify(port, buffer, actor, inbox) do
    actor = actor || row(buffer, "Actor URI:")
    inbox = inbox || row(buffer, "Shared inbox:")

    if actor && inbox do
      # kept for a failure message: it follows before it prints the table, so all it said about that is in here
      %{port: port, actor: actor, inbox: inbox, startup: buffer}
    else
      receive do
        {^port, {:data, data}} -> read_fedify(port, buffer <> data, actor, inbox)
        {^port, {:exit_status, status}} -> flunk("fedify inbox exited (#{status}): #{buffer}")
      after
        60_000 -> flunk("fedify inbox did not start within 60s: #{buffer}")
      end
    end
  end

  # what `fedify inbox` has printed since it started: what it did, how it checked what it received, and what it answered. Kept in the process dictionary as it is read, so reading it again loses nothing
  defp fedify_output(%{port: port, startup: startup}) do
    output = (Process.get({:fedify_output, port}) || startup) <> drain(port, "")
    Process.put({:fedify_output, port}, output)
    output
  end

  defp drain(port, acc) do
    receive do
      {^port, {:data, data}} -> drain(port, acc <> data)
    after
      0 -> acc
    end
  end

  # waits until Fedify has said `text`, reading its output as it comes; false after `seconds`
  defp await_output(fedify, text, seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    do_await_output(fedify, text, deadline)
  end

  defp do_await_output(%{port: port} = fedify, text, deadline) do
    if String.contains?(fedify_output(fedify), text) do
      true
    else
      left = deadline - System.monotonic_time(:millisecond)

      receive do
        {^port, {:data, data}} ->
          Process.put({:fedify_output, port}, fedify_output(fedify) <> data)
          do_await_output(fedify, text, deadline)
      after
        max(left, 0) -> false
      end
    end
  end

  # the URL in the table row labelled `label` of `fedify inbox`'s output
  defp row(output, label) do
    case Regex.run(~r/#{Regex.escape(label)}\s*│\s*(\S+)/u, output) do
      [_, url] -> url
      _ -> nil
    end
  end

  @tag :test_instance
  # ExUnit's own `skip:`, which still applies under `--only test_instance`
  @tag skip:
         (is_nil(@fedify) && "needs the fedify CLI on the PATH") ||
           (System.get_env("TUNNELED") != "yes" &&
              "needs both dance instances tunnelled: just test-federation-dance-tunneled")
  @tag timeout: :timer.minutes(10)
  test "a reply from the other instance to our user's post is forwarded to Fedify, which accepts it on the replier's proof",
       context do
    alice = context[:local][:user]
    alice_url = context[:local][:canonical_url]

    test_pid = self()

    # what the receiver decided about forwarding, watched as it happens (it still runs); `:global`, as it runs in the instance's processes
    Repatch.patch(Forwarder, :maybe_forward, [mode: :global], fn received, result, forwarding ->
      send(test_pid, {:forwarding, received["id"], received["type"], forwarding})
      Repatch.real(Forwarder.maybe_forward(received, result, forwarding))
    end)

    # signed by its author (FEP-8b32), as only such a reply is forwarded
    Application.put_env(:activity_pub, :sign_object_integrity_proofs, true)

    # Fedify's actor follows our user: it sends the Follow before it says who it is, so what arrives is counted from before it starts
    since = DateTime.utc_now()
    fedify = start_fedify_inbox(alice_url)
    IO.puts("fedify inbox: #{fedify.actor}, shared inbox #{fedify.inbox}")

    Interop.await_incoming([type: "Follow", from: fedify.actor], seconds: @wait, since: since) ||
      flunk(
        "no Follow from #{fedify.actor} reached us within #{@wait}s; fedify said:\n#{fedify_output(fedify)}"
      )

    # a user on the other instance follows ours too, so our post reaches the replier's instance
    TestInstanceRepo.apply(fn ->
      assert {:ok, alice_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(alice_url)
      assert {:ok, _follow} = Follows.follow(context[:remote][:user], alice_on_remote)
    end)

    text = "a post to reply to #{System.unique_integer([:positive])}"

    {:ok, _post} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    # the user on the other instance replies to it
    TestInstanceRepo.apply(fn ->
      replier = fancy_fake_user!("Replier")[:user]

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:my, text,
                 current_user: context[:remote][:user]
               )

      assert {:ok, _reply} =
               Posts.publish(
                 current_user: replier,
                 post_attrs: %{
                   post_content: %{html_body: "a reply from the other instance"},
                   reply_to_id: activity.object.id
                 },
                 boundary: "public"
               )
    end)

    # we forward it to Fedify's inbox
    assert_receive {:forwarding, reply_activity_id, "Create", {:ok, %{inboxes: inboxes}}},
                   @wait * 1000

    fedify_inbox = fedify.inbox

    assert fedify_inbox in inboxes,
           "the reply was forwarded, but not to Fedify's inbox #{fedify_inbox}: #{inspect(inboxes)}"

    # and Fedify accepts it, as it says: it processes only what it could verify (here, by the replier's proof, as the HTTP signature is our user's), and refuses the rest with an error
    assert await_output(fedify, "Activity '#{reply_activity_id}' has been processed", @wait),
           "Fedify did not process the forwarded reply #{reply_activity_id} within #{@wait}s, so it did not accept the replier's proof; fedify said:\n#{fedify_output(fedify)}"
  end
end
