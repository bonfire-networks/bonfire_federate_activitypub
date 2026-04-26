defmodule Bonfire.Federate.ActivityPub.RepairCorruptedActorPointers do
  @moduledoc """
  Repairs ap_objects rows where the pointer_id was corrupted by the incoming.ex
  `Enums.id(activity) || Enums.id(object)` fallback bug.

  Two corruption shapes are repaired:

  - Shape A: a non-actor AP object (Add, Video, etc.) was given pointer_id pointing to a
    local character (user, category, group, etc.). Fixed by nulling the pointer_id.

  - Shape B: a local actor AP object (Person, Group, etc.) had its pointer_id overwritten.
    Fixed by restoring pointer_id by matching preferredUsername to a known local character.
  """

  import Ecto.Query
  alias Bonfire.Common.Repo

  def run do
    {a, _} = repair_shape_a()
    {b, _} = repair_shape_b()
    {a + b, nil}
  end

  # Shape A: non-actor AP objects pointing to any local character (user, category, group, etc.)
  # — null out the pointer_id. Safe: non-actor types (Add, Video, Note, etc.) should never
  # point to character records. Post/activity objects with pointer_ids to posts are unaffected
  # (posts are not in bonfire_data_identity_character).
  defp repair_shape_a do
    Repo.query!("""
    UPDATE ap_object
    SET pointer_id = NULL
    WHERE data->>'type' NOT IN ('Person', 'Group', 'Organization', 'Service', 'Application', 'Tombstone')
      AND pointer_id IS NOT NULL
      AND pointer_id IN (SELECT id FROM bonfire_data_identity_character)
    """)
    |> then(&{&1.num_rows, nil})
  end

  # Shape B: local actor AP object (Person, Group, etc.) whose pointer_id no longer
  # matches the character — restore it by matching preferredUsername to character username.
  # Safe: only touches actor objects whose preferredUsername matches a known local character,
  # and whose current pointer_id is NOT already correct.
  defp repair_shape_b do
    Repo.query!("""
    UPDATE ap_object ap
    SET pointer_id = c.id
    FROM bonfire_data_identity_character c
    WHERE ap.data->>'type' IN ('Person', 'Group', 'Organization', 'Service', 'Application')
      AND ap.data->>'preferredUsername' = c.username
      AND (ap.pointer_id IS NULL OR ap.pointer_id != c.id)
    """)
    |> then(&{&1.num_rows, nil})
  end
end
