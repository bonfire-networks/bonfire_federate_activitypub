defmodule Bonfire.Federate.ActivityPub.ValidateC2SRecipientsTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter

  # whole file is a deferred spec for unimplemented C2S recipient-reachability validation
  @moduletag :todo

  # TODO: synchronously validate recipient reachability for MLS control messages
  # (PublicMessage/Welcome/GroupInfo) and return an error to the C2S client, instead of silently
  # delivering to a subset (which desyncs group state) when an addressed actor can't be reached
  # (e.g. `federation_allowed?` is false). It must happen here in the request path: the real
  # publish is async (APPublisher enqueues delivery), so a publish-time drop can't be surfaced to
  # the client. Resolution is host-specific, so it needs an adapter callback — but recipients are
  # *already* resolved later in the host receive handler (e.g. bonfire_encrypt's
  # `ap_receive_activity`), so ideally resolve once and thread the result through rather than twice

  # a recipient that cannot be resolved or fetched (not handled by the mock below)
  @unreachable "https://unreachable.example/users/nobody"

  setup_all do
    mock_global(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  describe "MLS control messages (strict: every recipient must be reachable)" do
    @describetag :todo
    for type <- ["PublicMessage", "Welcome", "GroupInfo"] do
      test "rejects a #{type} addressed to an unreachable recipient" do
        activity = %{
          "type" => "Create",
          "object" => %{"type" => unquote(type), "to" => [@unreachable]}
        }

        assert {:error, unreachable} = Adapter.validate_c2s_recipients(activity)
        assert @unreachable in unreachable
      end
    end
  end

  describe "non-control messages (lenient: tolerate unreachable recipients)" do
    @describetag :todo
    test "allows a PrivateMessage even when a recipient is unreachable" do
      activity = %{
        "type" => "Create",
        "object" => %{"type" => "PrivateMessage", "to" => [@unreachable]}
      }

      assert :ok = Adapter.validate_c2s_recipients(activity)
    end

    test "allows a plain Note even when a recipient is unreachable" do
      activity = %{
        "type" => "Create",
        "object" => %{"type" => "Note", "to" => [@unreachable]}
      }

      assert :ok = Adapter.validate_c2s_recipients(activity)
    end
  end
end
