defmodule Bonfire.Federate.ActivityPub.InboxUnsignedJunkTest do
  @moduledoc """
  What an unsigned delivery to the shared inbox costs us before anything vouches for it: it does not make us believe the host it names is reachable, and the same document posted again does not queue another job.

  The deliveries are posted with no `Signature` header, as anyone on the internet can. The control is a delivery with a verified HTTP signature (faked the way the fork's controller tests do it: assign `valid_signature: true`), which is processed. These tests need the Oban queues in manual mode (the default; with `FEDERATE` set jobs run as they are queued).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Tests.ObanHelpers

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  # a host nobody here knows to be up, and the actor of somebody who claims to be on it
  @junk_host "evil.local"
  @junk_actor "https://evil.local/users/ghost"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor))
      %{method: :get, url: @junk_actor} -> json(Simulate.actor_json(@junk_actor, "ghost"))
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    # known, so a delivery signed by it is mapped to it (a signature by an unknown actor is not honoured, and the delivery is verified like an unsigned one)
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @junk_actor)

    :ok
  end

  # a Create from `actor`, with an id of its own
  defp create_doc(actor, to) do
    note_id = "#{String.replace(actor, ~r{/users/.*}, "")}/notes/#{Needle.UID.generate()}"

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => note_id <> "/activity",
      "type" => "Create",
      "actor" => actor,
      "to" => to,
      "cc" => [],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => actor,
        "content" => "junk #{System.unique_integer([:positive])}",
        "to" => to,
        "cc" => []
      }
    }
  end

  defp post_unsigned(doc) do
    build_conn()
    |> put_req_header("content-type", "application/activity+json")
    |> post("/pub/shared_inbox", doc)
  end

  defp post_signed(signer, doc) do
    build_conn()
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"#{signer}#main-key\"")
    |> put_req_header("content-type", "application/activity+json")
    |> post("/pub/shared_inbox", doc)
  end

  defp enqueued_for(doc),
    do: Oban.Testing.all_enqueued(repo(), args: %{"params" => %{"id" => doc["id"]}})

  # the host is one we gave up on
  defp written_off!(host) do
    {:ok, _} = ActivityPub.Instances.set_unreachable("https://#{host}")
    assert %{unreachable_since: since} = ActivityPub.Instances.Instance.get_by_host(host)
    assert since, "control: #{host} is marked unreachable"
  end

  defp unreachable_since(host),
    do: ActivityPub.Instances.Instance.get_by_host(host).unreachable_since

  describe "reachability" do
    test "control: a signed delivery from a host marks it reachable" do
      written_off!(@junk_host)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      assert post_signed(@junk_actor, create_doc(@junk_actor, [recipient_actor.ap_id])).status ==
               200

      assert is_nil(unreachable_since(@junk_host)), "control: the signed delivery cleared it"
    end

    test "an unsigned delivery naming an actor on a host does not mark that host reachable" do
      written_off!(@junk_host)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      post_unsigned(create_doc(@junk_actor, [recipient_actor.ap_id]))

      refute is_nil(unreachable_since(@junk_host)),
             "an unsigned delivery cleared the unreachable mark of #{@junk_host}"
    end
  end

  describe "queued jobs" do
    test "control: a signed delivery is queued and processed" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
      doc = create_doc(@remote_actor, [recipient_actor.ap_id])

      assert post_signed(@remote_actor, doc).status == 200
      assert [_] = enqueued_for(doc), "control: it is queued"

      ObanHelpers.perform_all()

      assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: doc["object"]["id"])
    end

    test "the same unsigned delivery posted five times is queued once" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
      doc = create_doc(@junk_actor, [recipient_actor.ap_id])

      post_unsigned(doc)
      assert [_] = enqueued_for(doc), "control: the first one is queued"

      for _ <- 1..4, do: post_unsigned(doc)

      assert length(enqueued_for(doc)) == 1,
             "the same document was queued #{length(enqueued_for(doc))} times"
    end
  end
end
