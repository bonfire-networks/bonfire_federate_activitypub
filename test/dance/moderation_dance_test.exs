defmodule Bonfire.Federate.ActivityPub.Dance.ModerationDanceTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  test "Ghosting a remote user works" do
  end

  test "Silencing a remote user works" do
  end

  describe "if I silenced a remote user i will not receive any update from it" do
    test "i'll not see anything they publish in feeds" do
    end

    test "i'll be able to view their profile or read post via direct link" do
    end

    test "i'll not see any @ mentions or DMs from them" do
    end

    test "I'll not be able to follow them" do
    end

    test "if I unsilence them i'll not be able to see previously missed updates" do
    end
  end

  describe "if I ghosted a remote user they will not be able to interact with me or with my content" do
    test "Nothing I post privately will be shown to them from now on" do
    end

    test "They will still be able to see things I post publicly. " do
    end

    test "I won't be able to @ mention or message them. " do
    end

    test "they won't be able to follow me" do
    end

    test "You will be able to undo this later but they may not be able to see any activities they missed." do
    end
  end

  describe "Admin" do
    test "As an admin I can ghost a remote user instance-wide" do
    end

    test "As an admin I can silence a remote user instance-wide" do
    end
  end
end
