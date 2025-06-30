defmodule Bonfire.Federate.ActivityPub.Dance.MentionsPrivateMediaTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.{Circles, Acls, Grants}

  @tag :test_instance
  test "post with media attachment dances elegantly", context do
    # context |> info("context")

    assert {:ok, remote_recipient_on_local} =
             AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

    local_user = context[:local][:user]
    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        local_user,
        Bonfire.Files.Simulation.icon_file(),
        %{
          metadata: %{label: "Post Media"}
        }
      )

    post1_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} msg1"},
      uploaded_media: [media]
    }

    {:ok, post1} =
      Posts.publish(
        current_user: local_user,
        post_attrs: post1_attrs,
        boundary: "mentions"
        # to_circles: [remote_recipient_on_local]
      )
      |> repo().maybe_preload(activity: [:tagged])

    error(post1.activity.tagged)

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local")) 
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    assert List.first(List.wrap(post1.activity.federate_activity_pub.data["to"])) ==
             remote_ap_id ||
             List.first(List.wrap(post1.activity.federate_activity_pub.data["cc"])) ==
               remote_ap_id

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      # remote_user = context[:remote][:user]
      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      # Bonfire.Posts.list_by(local_on_remote)
      posts =
        Bonfire.Messages.list(local_on_remote)
        |> debug("list")

      assert match?(%{edges: [feed_entry | _]}, posts),
             "post 1 wasn't federated to instance of mentioned actor"

      %{edges: [feed_entry | _]} = posts

      post1remote = feed_entry.activity.object
      assert post1remote.post_content.html_body =~ "msg1"
      assert post1remote.post_content.html_body =~ context[:remote][:username]
    end)

    ## back to primary instance
  end
end
