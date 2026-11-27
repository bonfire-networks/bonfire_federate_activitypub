defmodule Bonfire.Federate.ActivityPub.Test.HTMLOutputEditor do
  @moduledoc "A stand-in for a rich text editor that stores HTML (as Quill does), for tests that publish through the HTML path. Set it with `Settings.put([:ui, :rich_text_editor], ...)`."

  def output_format, do: :html
end
