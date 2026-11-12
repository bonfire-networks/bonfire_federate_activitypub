defmodule Bonfire.Federate.ActivityPub.GroupPageRedirectTest do
  @moduledoc """
  A server fetching a group's page with an ActivityPub `Accept` header is sent to the group's actor, as it is for a user's page (`actor_integration_test.exs`) and a post's: to our actor id for a group of ours, and to its id on its own server for a group we mirror.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  alias Bonfire.Common.URIs

  defp redirect_of(path) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> get(path)
    |> redirected_to()
  end

  setup do
    group = Bonfire.Classify.Simulate.fake_group!(fake_user!(), %{visibility: "global"})
    {:ok, group: group, actor_id: URIs.canonical_url(group, preload_if_needed: true)}
  end

  test "a group's page by its name goes to its actor", %{group: group, actor_id: actor_id} do
    # the positive first: the group has an actor id of its own here
    assert actor_id =~ URIs.base_url() <> "/pub/"

    assert redirect_of("/&#{group.character.username}") == actor_id
  end

  test "a group's page by its id goes to its actor", %{group: group, actor_id: actor_id} do
    assert redirect_of("/group/#{group.id}") == actor_id
  end

  test "a topic's page inside its group goes to the topic, not the group", %{
    group: group,
    actor_id: group_actor_id
  } do
    topic =
      Bonfire.Classify.Simulate.fake_category!(fake_user!(), group, %{
        name: "Race reports",
        type: :topic
      })

    topic_id = URIs.canonical_url(topic, preload_if_needed: true)
    # the positive first: the topic has an id of its own here, which isn't the group's
    assert topic_id =~ URIs.base_url() <> "/pub/"
    refute topic_id == group_actor_id

    assert redirect_of(Bonfire.Classify.Web.GroupNavigation.topic_path(group, topic)) == topic_id
  end

  test "a mirrored group's page goes to its id on its own server", %{group: group} do
    assert {:ok, _} =
             Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
               group,
               "https://elsewhere.local/c/mirrored"
             )

    assert redirect_of("/group/#{group.id}") == "https://elsewhere.local/c/mirrored"
  end
end
