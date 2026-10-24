defmodule Bonfire.Federate.ActivityPub.RelayedBackTest do
  @moduledoc """
  One of our own activities, relayed back to us by a group hosted elsewhere (FEP-1b12).

  Our own post or edit took effect when we made it, so its relayed copy is only acknowledged. Applying it again would publish it again, which the group would announce again, and so on: a loop between the two instances that only a timeout ends.

  Our moderation of a group hosted elsewhere is different, and still handled: unless it was applied at once (`apply_now`), it waits for the group, and the relayed copy is what applies it (the dance tests in `group_post_dance_test.exs` cover that).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Posts

  @group "https://groups.example/c/group"

  setup do
    user = fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "a post of ours, in a group elsewhere"}},
        boundary: "public"
      )

    post_url = Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)
    actor_url = Bonfire.Common.URIs.canonical_url(user)

    %{post_url: post_url, actor_url: actor_url}
  end

  defp ours_relayed_back(type, %{post_url: post_url, actor_url: actor_url}),
    do: %ActivityPub.Object{
      local: true,
      relayed_by: @group,
      data: %{
        "id" => "#{post_url}/#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "actor" => actor_url,
        "object" => post_url
      }
    }

  for type <- ["Create", "Update"] do
    test "our own #{type} relayed back is only acknowledged, not applied again", context do
      assert {:ok, :already_applied} =
               Incoming.receive_activity(ours_relayed_back(unquote(type), context))
    end
  end
end
