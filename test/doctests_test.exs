defmodule Bonfire.Federate.ActivityPub.DocsTest do
  # `:federation` comes with this case
  use Bonfire.Federate.ActivityPub.DataCase, async: true

  doctest Bonfire.Federate.ActivityPub.AdapterUtils, import: true
end
