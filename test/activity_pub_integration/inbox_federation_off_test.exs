defmodule Bonfire.Federate.ActivityPub.InboxFederationOffTest do
  @moduledoc """
  What the inboxes do with incoming activities when federation is turned off, for the whole instance or by one local user.

  Signature verification is faked the way the fork's controller tests do it (assign `valid_signature: true` and a `keyId` header), so these tests cover what we do with a signed delivery, not the cryptography.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Tests.ObanHelpers
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Messages

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: "https://mocked.local/.well-known/" <> _} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    # the instance mode is saved into Application env, which the sandbox doesn't roll back, so put back what was there
    instance_config = Application.get_env(:activity_pub, :instance)
    on_exit(fn -> Application.put_env(:activity_pub, :instance, instance_config) end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    :ok
  end

  # the same call the instance settings page makes when the admin picks "Disabled" (`Bonfire.Common.Settings.LiveHandler` "set" event of `FederationModeLive`)
  defp admin_turns_instance_federation_off! do
    admin = fake_admin!()

    {:ok, _} =
      Bonfire.Common.Settings.set(
        %{"scope" => "instance", "activity_pub" => %{"instance" => %{"federating" => "false"}}},
        current_user: admin
      )
  end

  # the same setting the user's safety settings page writes when they pick "Disabled"
  defp turn_user_federation_off!(user) do
    current_user(Settings.put([:activity_pub, :user_federating], false, current_user: user))
  end

  defp create_doc(recipients, text) do
    note_id = "#{@remote_instance}/notes/#{Needle.UID.generate()}"
    to = Enum.map(recipients, & &1.ap_id)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => note_id <> "/activity",
      "type" => "Create",
      "actor" => @remote_actor,
      "to" => to,
      "cc" => [],
      "object" => %{
        "id" => note_id,
        "type" => "Note",
        "attributedTo" => @remote_actor,
        "content" => text,
        "to" => to,
        "cc" => [],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "tag" =>
          Enum.map(recipients, fn actor ->
            %{"type" => "Mention", "href" => actor.ap_id, "name" => "@" <> actor.username}
          end)
      }
    }
  end

  defp deliver(path, doc) do
    build_conn()
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"#{@remote_actor}#main-key\"")
    |> put_req_header("content-type", "application/activity+json")
    |> post(path, doc)
  end

  defp actor_inbox(actor), do: "/pub/actors/#{actor.username}/inbox"

  defp enqueued_for(doc),
    do: Oban.Testing.all_enqueued(repo(), args: %{"params" => %{"id" => doc["id"]}})

  defp local_object_id(doc) do
    case ActivityPub.Object.get_cached(ap_id: doc["object"]["id"]) do
      {:ok, %{pointer_id: pointer_id}} -> pointer_id
      _ -> nil
    end
  end

  defp text, do: "inbox federation off #{System.unique_integer([:positive])}"

  # a private Note to named users arrives as a message, which is listed with the user's messages rather than in their notifications feed, so both are checked
  defp reached?(user, doc, text) do
    id = local_object_id(doc)

    (is_binary(id) and Enum.any?(e(Messages.list(user), :edges, []), &(id(&1) == id))) or
      FeedLoader.feed_contains?(:notifications, text, current_user: user)
  end

  test "with instance federation turned off by the admin, the shared inbox refuses a signed Create and queues nothing" do
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
    doc = create_doc([recipient_actor], text())

    admin_turns_instance_federation_off!()

    # the inbox controller reads the instance mode from the `:activity_pub` app env, so the admin's setting has to land there
    assert ActivityPub.Config.federating?() == false,
           "the admin setting did not reach the app env: #{inspect(Application.get_env(:activity_pub, :instance)[:federating])}"

    conn = deliver("/pub/shared_inbox", doc)

    assert conn.status == 403
    assert enqueued_for(doc) == []
  end

  test "control: a signed Create to a user who federates is accepted at their inbox and reaches them" do
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
    text = text()
    doc = create_doc([recipient_actor], text)

    conn = deliver(actor_inbox(recipient_actor), doc)
    assert conn.status == 200

    ObanHelpers.perform_all()

    assert local_object_id(doc)
    assert reached?(recipient, doc, text)
  end

  test "a user who turned federation off: their inbox refuses a signed Create addressed only to them" do
    recipient = fake_user!() |> turn_user_federation_off!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
    text = text()
    doc = create_doc([recipient_actor], text)

    conn = deliver(actor_inbox(recipient_actor), doc)

    assert conn.status == 403
    assert enqueued_for(doc) == []

    ObanHelpers.perform_all()

    refute local_object_id(doc)
    refute reached?(recipient, doc, text)
  end

  test "a user who turned federation off: a signed Create addressed only to them via the shared inbox creates nothing and doesn't notify them" do
    recipient = fake_user!() |> turn_user_federation_off!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)
    text = text()
    doc = create_doc([recipient_actor], text)

    deliver("/pub/shared_inbox", doc)

    ObanHelpers.perform_all()

    refute local_object_id(doc)
    refute reached?(recipient, doc, text)
  end

  test "a Create addressed to a user who turned federation off and to another local user reaches only the other user" do
    opted_out = fake_user!() |> turn_user_federation_off!()
    opted_out_actor = ActivityPub.Actor.get_cached!(pointer: opted_out.id)
    other = fake_user!()
    other_actor = ActivityPub.Actor.get_cached!(pointer: other.id)
    text = text()
    doc = create_doc([opted_out_actor, other_actor], text)

    conn = deliver("/pub/shared_inbox", doc)
    assert conn.status == 200

    ObanHelpers.perform_all()

    assert id = local_object_id(doc)

    assert reached?(other, doc, text)
    assert {:ok, _} = Messages.read(id, current_user: other)

    refute reached?(opted_out, doc, text)
    assert {:error, _} = Messages.read(id, current_user: opted_out)
  end
end
