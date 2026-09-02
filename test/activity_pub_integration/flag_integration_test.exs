defmodule Bonfire.Federate.ActivityPub.FlagIntegrationTest do
  @moduledoc """
  Incoming reports, and specifically the Mastodon shape where ONE report names several objects.

  A Mastodon report is a `Flag` whose `object` is a list: the reported account, plus the statuses submitted as evidence about them. A single report therefore has to become a moderation record for each thing it names, and each has to keep the reason, since a report reaching a moderator without what it was about is barely a report.

  ⚠️ The list is NOT a batch of independent activities, which is why the generic per-element fan-out (`Transformer.handle_each_object/3`, used for a batched `Announce`) deliberately does not claim `Flag`. Fanning a report out at the transformer would turn one report into several, each stripped of the others as context; the fan-out belongs at the point where records are created, which is where it happens.
  """
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Posts
  alias Bonfire.Social.Flags
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  import Tesla.Mock

  @reporter "https://mocked.local/users/karen"
  @reason "spamming the same thing repeatedly"

  setup do
    mock(fn
      %{method: :get, url: @reporter} ->
        json(Simulate.actor_json(@reporter))

      %{method: :get, url: "https://mocked.local/.well-known/webfinger" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  # `canonical_url/1` refuses to guess: it wants `:peered` loaded at the source, so that a remote object's own id is used rather than a local URL being invented for it. These are local, but the preload is still what makes the call legitimate.
  defp ap_id(%Bonfire.Data.Identity.User{} = user),
    do: user |> repo().maybe_preload(character: [:peered]) |> canonical_url()

  defp ap_id(object),
    do:
      object
      |> repo().maybe_preload([:peered, created: [creator: [character: [:peered]]]])
      |> canonical_url()

  describe "a report naming several objects" do
    test "flags every one of them, keeping the reason" do
      reported = fake_user!()

      posts =
        for body <- ["<p>first offending post</p>", "<p>second offending post</p>"] do
          assert {:ok, post} =
                   Posts.publish(
                     current_user: reported,
                     post_attrs: %{post_content: %{html_body: body}},
                     boundary: "public"
                   )

          post
        end

      # the Mastodon shape: the reported account first, then the statuses offered as evidence
      objects = [ap_id(reported) | Enum.map(posts, &ap_id/1)]

      flag = %{
        "type" => "Flag",
        "id" => "https://mocked.local/activities/flag/#{System.unique_integer([:positive])}",
        "actor" => @reporter,
        "object" => objects,
        "content" => @reason
      }

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(flag)

      reporter = AdapterUtils.get_character_by_ap_id!(@reporter)

      for object <- [reported | posts] do
        assert Flags.flagged?(reporter, object),
               "the report names #{uid(object)}, so it should be flagged: a moderator needs the account AND the evidence, not whichever resolved first"
      end
    end

    test "keeps the reason on the flags it creates" do
      reported = fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: reported,
                 post_attrs: %{post_content: %{html_body: "<p>offending post</p>"}},
                 boundary: "public"
               )

      flag = %{
        "type" => "Flag",
        "id" => "https://mocked.local/activities/flag/#{System.unique_integer([:positive])}",
        "actor" => @reporter,
        "object" => [ap_id(reported), ap_id(post)],
        "content" => @reason
      }

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(flag)

      assert %{edges: [flagged | _]} =
               Flags.list_of(post, current_user: reported, skip_boundary_check: true)

      assert e(repo().maybe_preload(flagged, :named), :named, :name, nil) == @reason,
             "the reason is what makes a report actionable, so it must survive onto each record"
    end
  end
end
