defmodule Bonfire.Federate.ActivityPub.Boundaries.KeywordsMRFPerUserTest do
  @moduledoc """
  An incoming post containing one of a local person's filtered keywords is not delivered to them: they are dropped from its recipients, and a post left with nobody to deliver to is rejected. Others it is addressed to still get it.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Boundaries.BlockKeywords

  @remote_actor "https://mocked.local/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    alice = fake_user!()
    bob = fake_user!()
    {:ok, _} = BlockKeywords.put_block_keywords_settings(["viagra"], current_user: alice)

    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    {:ok, alice: alice, bob: bob, actor: actor}
  end

  defp remote_post(actor, to, content),
    do: remote_activity_json(actor.ap_id, local_actor_ids(to), %{"content" => content})

  test "a direct message with one of its only recipient's keywords is rejected", %{
    alice: alice,
    actor: actor
  } do
    # the positive first: without her keyword, it reaches her
    assert {:ok, _} = BoundariesMRF.filter(remote_post(actor, [alice], "hello there"), false)

    assert {:reject, _} =
             BoundariesMRF.filter(remote_post(actor, [alice], "cheap viagra for you"), false)
  end

  test "a message to two people goes only to the one whose keywords it doesn't match", %{
    alice: alice,
    bob: bob,
    actor: actor
  } do
    bobs_ap_id = local_actor_ids(bob)

    assert {:ok, %{to: [^bobs_ap_id]}} =
             BoundariesMRF.filter(remote_post(actor, [alice, bob], "cheap viagra for you"), false)
  end

  test "a message to two people that matches nobody's keywords goes to both", %{
    alice: alice,
    bob: bob,
    actor: actor
  } do
    to = local_actor_ids([alice, bob])

    assert {:ok, %{to: ^to}} =
             BoundariesMRF.filter(remote_post(actor, [alice, bob], "hello there"), false)
  end

  test "a public post addressed to her that matches stays public, without her", %{
    alice: alice,
    actor: actor
  } do
    public_uri = ActivityPub.Config.public_uri()

    assert {:ok, %{to: [^public_uri]}} =
             BoundariesMRF.filter(
               remote_post(actor, [alice, public_uri], "cheap viagra for you"),
               false
             )
  end

  test "an incoming post is matched once against the instance's list, and once per recipient who has a list",
       %{alice: alice, bob: bob, actor: actor} do
    # string keys, as an incoming activity has them (the keyword policy reads no other)
    activity =
      remote_post(actor, [alice, bob], "hello there")
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    mfa = {ActivityPub.MRF.KeywordMatcher, :match?, 3}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      assert {:ok, _} =
               ActivityPub.MRF.filter(
                 [ActivityPub.MRF.KeywordPolicy, BoundariesMRF],
                 activity,
                 false
               )

      # the instance's list once, alice's once; bob has no list
      assert {:call_count, 2} == :erlang.trace_info(mfa, :call_count)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "an edit that adds one of her keywords drops her too", %{alice: alice, actor: actor} do
    public_uri = ActivityPub.Config.public_uri()

    update =
      remote_post(actor, [alice, public_uri], "now with viagra")
      |> Map.put(:type, "Update")

    assert {:ok, %{to: [^public_uri]}} = BoundariesMRF.filter(update, false)
  end
end
