defmodule Bonfire.Federate.ActivityPub.Dance.MessageTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Messages
  alias Bonfire.Social.Follows
  alias Bonfire.Boundaries.{Circles, Acls, Grants}

  @tag :test_instance
  test "message dances elegantly", context do
    # context |> info("context")

    assert {:ok, remote_recipient_on_local} =
             AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

    message1_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} msg1"}
    }

    message2_attrs = %{post_content: %{html_body: "msg2"}}

    message3_attrs = %{
      post_content: %{
        html_body: "#{context[:local][:username]} msg3"
      }
    }

    message4_attrs = %{post_content: %{html_body: "msg4"}}
    message5_attrs = %{post_content: %{html_body: "msg5"}}

    local_user = context[:local][:user]
    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    {:ok, message1} = Messages.send(local_user, message1_attrs, remote_recipient_on_local)

    error(message1.activity.tagged)

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local")) 
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    assert List.first(List.wrap(message1.activity.federate_activity_pub.data["to"])) ==
             remote_ap_id

    ## work on test instance
    TestInstanceRepo.apply(fn ->
      remote_user = context[:remote][:user]
      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      messages =
        Bonfire.Social.Messages.list(remote_user)
        |> debug("list")

      assert match?(%{edges: [feed_entry | _]}, messages),
             "message 1 wasn't federated to instance of mentioned actor"

      %{edges: [feed_entry | _]} = messages
      message1remote = feed_entry.activity.object
      assert message1remote.post_content.html_body =~ message1_attrs.post_content.html_body

      Logger.metadata(action: info("attempt a reply without TO on remote"))

      {:error, _} =
        Messages.send(
          remote_user,
          message2_attrs |> Map.put(:reply_to_id, ulid(message1remote))
        )

      Logger.metadata(action: info("make a reply with TO on remote"))

      {:ok, message3} =
        Messages.send(
          remote_user,
          message3_attrs |> Map.put(:reply_to_id, ulid(message1remote)),
          local_on_remote
        )

      # raise nil

      Logger.metadata(action: info("attempt a message in thread without TO on remote"))

      {:error, _} =
        Messages.send(
          remote_user,
          message4_attrs |> Map.put(:thread_id, ulid(message1remote))
        )

      Logger.metadata(action: info("message in thread on remote"))

      {:ok, message5} =
        Messages.send(
          remote_user,
          message5_attrs |> Map.put(:reply_to_id, ulid(message1remote)),
          local_on_remote
        )
    end)

    ## back to primary instance

    Logger.metadata(action: info("check that reply-only is NOT in OP's messages"))

    assert %{edges: messages} =
             Bonfire.Social.Messages.list(local_user) |> debug("feeeed")

    Enum.each(
      messages,
      &refute(&1.activity.object.post_content.html_body =~ message2_attrs.post_content.html_body)
    )

    Logger.metadata(
      action: info("check that reply with mention was federated and is in OP's messages")
    )

    assert Bonfire.Social.FeedActivities.feed_contains?(
             messages,
             message3_attrs.post_content.html_body
           ),
           "reply with mention should be in OP's messages"

    Logger.metadata(
      action: info("check that reply without mention was federated and is in local messages")
    )

    assert %{edges: messages} =
             Bonfire.Social.Messages.list(local_user)
             |> debug("feeeedlocal")

    assert Bonfire.Social.FeedActivities.feed_contains?(
             messages,
             message5_attrs.post_content.html_body
           ),
           "the repply in thread should be received"

    # TODO ^ check that message5 is in the correct thread
  end
end
