defmodule Bonfire.Federate.ActivityPub.PersonActorDeclarationsTest do
  @moduledoc """
  What our own Person actor declares about being followed.

  `manuallyApprovesFollowers` is the AS2 field Mastodon reads (and everything that copies Mastodon) to show a follow as PENDING rather than accepted. Bonfire accounts can require approval (`request_before_follow` puts a `:no_follow` boundary in place at signup, per user or instance-wide via `Config.get([Bonfire.Me.Users, :request_before_follow])`), and an account that reviews follows declares it, so the remote holds the follow as pending rather than offering a plain Follow button and waiting on an `Accept` that only a human decision can produce. Stated either way rather than omitted, since an absent flag reads as unknown rather than as open.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Graph.Follows

  defp actor_data(user) do
    assert %{data: data} = AdapterUtils.format_actor(user)
    data
  end

  test "a user who reviews follows says so" do
    user = fake_user!(%{}, %{}, request_before_follow: true)

    assert actor_data(user)["manuallyApprovesFollowers"] == true,
           "this is the only thing a remote reads before deciding whether to show the follow as pending"
  end

  test "a user anyone may follow says that too" do
    user = fake_user!()

    assert actor_data(user)["manuallyApprovesFollowers"] == false
  end

  # The invariant worth pinning, since the declaration and the enforcement are separate code: what we advertise has to be what a follow actually meets. Both branches are exercised, because an assertion that only ever sees the locked case would equally pass on a field hardcoded to `true`.
  test "the declaration matches what a follow actually does" do
    for request_before_follow <- [true, false] do
      followed = fake_user!(%{}, %{}, request_before_follow: request_before_follow)
      follower = fake_user!()

      assert {:ok, _} = Follows.follow(follower, followed)

      assert actor_data(followed)["manuallyApprovesFollowers"] ==
               Follows.requested?(follower, followed),
             "a follow of this account is #{if request_before_follow, do: "held for approval", else: "accepted immediately"}, so the actor must say exactly that"
    end
  end
end
