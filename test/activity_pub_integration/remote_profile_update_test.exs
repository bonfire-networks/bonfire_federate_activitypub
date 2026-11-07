defmodule Bonfire.Federate.ActivityPub.RemoteProfileUpdateTest do
  @moduledoc """
  A remote person who changes their display name or bio has the change reach their profile here.

  Mastodon tells followers with an `Update` of the actor, delivered to their inboxes. Its embedded document is applied as-is only when the actor itself vouched for it (the delivery was signed by that actor); otherwise the document is ignored and the actor is refetched from its origin (`Transformer.handle_incoming/2` → `Actor.update_actor/5`). Either way the Bonfire profile is rewritten by `Adapter.update_remote_actor/2`. Both paths are covered, read back through what the profile page loads (`Bonfire.Me.Profiles.LiveHandler.get/1`) and through the cached actor that federation and rendering read.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @remote_actor "https://mastodon.local/users/liaizon"
  @public "https://www.w3.org/ns/activitystreams#Public"

  defp actor_doc(overrides),
    do: APSimulate.actor_json(@remote_actor, "liaizon", overrides)

  defp original,
    do: actor_doc(%{"name" => "Original name", "summary" => "<p>Original bio</p>"})

  defp origin_serves(doc) do
    mock(fn
      %{method: :get, url: @remote_actor} -> json(doc)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp update_activity(doc) do
    %{
      "type" => "Update",
      "id" => "#{@remote_actor}#updates/1",
      "actor" => @remote_actor,
      "object" => doc,
      "to" => [@public]
    }
  end

  defp profile_page_user(remote_user) do
    username = e(remote_user, :character, :username, nil)
    assert is_binary(username), "control: the remote user has a username to load the profile by"
    Bonfire.Me.Profiles.LiveHandler.get(username)
  end

  setup do
    origin_serves(original())

    assert {:ok, remote_user} =
             Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(original())

    remote_user = repo().maybe_preload(remote_user, [:character, :profile])

    # control: we start from the original name and bio, both on the profile page and in the cached actor, so the assertions after the Update mean something
    assert %{profile: %{name: "Original name", summary: "<p>Original bio</p>"}} =
             profile_page_user(remote_user)

    assert {:ok, %{data: %{"name" => "Original name"}}} =
             ActivityPub.Actor.get_cached(ap_id: @remote_actor)

    {:ok, remote_user: remote_user}
  end

  test "an Update signed by the actor itself changes the profile name and bio", %{
    remote_user: remote_user
  } do
    updated = actor_doc(%{"name" => "New name", "summary" => "<p>New bio</p>"})

    # the origin still serves the old document, so only applying the vouched-for document can make this pass
    assert {:ok, _} =
             Transformer.handle_incoming(update_activity(updated),
               authenticated: :http_signature,
               signed_by: @remote_actor
             )

    assert %{profile: %{name: "New name", summary: "<p>New bio</p>"}} =
             profile_page_user(remote_user),
           "a remote person who renames themself must not keep their old name here"

    assert {:ok, %{data: %{"name" => "New name", "summary" => "<p>New bio</p>"}}} =
             ActivityPub.Actor.get_cached(ap_id: @remote_actor),
           "the cached actor must not keep serving the old name"

    assert {:ok, %{data: %{"name" => "New name"}}} =
             ActivityPub.Actor.get_cached(pointer: id(remote_user)),
           "nor the actor cached under the profile's own id"
  end

  test "an Update not vouched for by the actor refetches it, and the profile takes the name and bio its origin serves",
       %{remote_user: remote_user} do
    origin_serves(actor_doc(%{"name" => "New name", "summary" => "<p>New bio</p>"}))

    # what anyone could forge: it is ignored in favour of what the origin serves
    forged = actor_doc(%{"name" => "Forged name", "summary" => "<p>Forged bio</p>"})

    assert {:ok, _} = Transformer.handle_incoming(update_activity(forged))

    assert %{profile: %{name: "New name", summary: "<p>New bio</p>"}} =
             profile_page_user(remote_user),
           "a remote person who renames themself must not keep their old name here"

    assert {:ok, %{data: %{"name" => "New name", "summary" => "<p>New bio</p>"}}} =
             ActivityPub.Actor.get_cached(ap_id: @remote_actor),
           "the cached actor must not keep serving the old name"

    assert {:ok, %{data: %{"name" => "New name"}}} =
             ActivityPub.Actor.get_cached(pointer: id(remote_user)),
           "nor the actor cached under the profile's own id"
  end
end
