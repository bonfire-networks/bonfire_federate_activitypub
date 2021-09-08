defmodule Bonfire.Federate.ActivityPub.MessageIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Messages

  test "can federate message" do
    me = fake_user!()
    messaged = fake_user!()
    msg = "hey you have an epic text message"
    attrs = %{circles: [messaged.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(me, attrs)

    {:ok, activity} = Messages.ap_publish_activity("create", message)

    assert activity.data["object"]["content"] == msg
  end
end
