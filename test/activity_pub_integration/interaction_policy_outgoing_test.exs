defmodule Bonfire.Federate.ActivityPub.InteractionPolicyOutgoingTest do
  @moduledoc """
  What an outgoing object's `interactionPolicy` tells other servers about who may interact with it.

  A mentioned user may interact unless the policy has a non-empty `automaticApproval` that leaves them out. So on a post the public can't reach, a verb its recipients all have is stated as `{}`, which the spec reads as "anyone who can see the post", and so its recipients, rather than as author-only, which the receiving side reads as a denial.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  alias Bonfire.Federate.ActivityPub.Outgoing

  @policy_verbs %{
    "canLike" => :like,
    "canAnnounce" => :boost,
    "canReply" => :reply,
    "canQuote" => :quote
  }

  defp policy_of(post) do
    assert {:ok, %{object: %{data: data}}} = Outgoing.push_now!(post)
    data["interactionPolicy"]
  end

  test "a mentions post states no restriction for each verb its recipient has, and author-only for the others" do
    creator = fake_user!()
    mentioned = fake_user!()

    post =
      Bonfire.Posts.Fake.fake_post!(creator, "mentions", %{
        post_content: %{html_body: "<p>just between us @#{mentioned.character.username}</p>"}
      })

    policy = policy_of(post)

    for {key, verb} <- @policy_verbs do
      if Bonfire.Boundaries.can?(mentioned, verb, post),
        do: assert(policy[key] == %{}, "#{key}: the recipient may, so no restriction"),
        else:
          assert(
            policy[key]["automaticApproval"] == [Bonfire.Common.URIs.canonical_url(creator)],
            "#{key}: author-only"
          )
    end

    assert Enum.any?(@policy_verbs, fn {_key, verb} ->
             Bonfire.Boundaries.can?(mentioned, verb, post)
           end),
           "control: the recipient has some verb"

    refute Enum.all?(@policy_verbs, fn {_key, verb} ->
             Bonfire.Boundaries.can?(mentioned, verb, post)
           end),
           "control: and lacks another, so both branches are asserted"
  end

  test "a public post still states Public, not `{}`, for what the public may do" do
    creator = fake_user!()
    mentioned = fake_user!()

    post =
      Bonfire.Posts.Fake.fake_post!(creator, "public", %{
        post_content: %{html_body: "<p>hello @#{mentioned.character.username}</p>"}
      })

    assert ActivityPub.Config.public_uri() in policy_of(post)["canReply"]["automaticApproval"]
  end
end
