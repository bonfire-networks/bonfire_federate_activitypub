defmodule Bonfire.Federate.ActivityPub.RepairCorruptedActorPointers do
  @moduledoc """
  Repairs ap_objects rows where the pointer_id was corrupted by the incoming.ex
  `Enums.id(activity) || Enums.id(object)` fallback bug.

  Two corruption shapes are repaired:

  - Shape A: a non-actor AP object (Add, Video, etc.) was given pointer_id pointing to a
    local character (user, category, group, etc.). Fixed by nulling the pointer_id.

  - Shape B: a local actor AP object (Person, Group, etc.) had its pointer_id overwritten.
    Fixed by restoring pointer_id by matching preferredUsername to a known local character.
    Only local rows are candidates, since a username is unique per instance and a remote actor may
    carry the same one. At most one row is repaired per character, since `ap_object.pointer_id` is
    unique and a character with several actor rows would otherwise have them all claim its id.
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

  defp repair_shape_b do
    Repo.query!("""
    UPDATE ap_object ap
    SET pointer_id = m.character_id
    FROM (
      SELECT DISTINCT ON (c.id) ap2.id AS ap_id, c.id AS character_id
      FROM ap_object ap2
      JOIN bonfire_data_identity_character c
        ON ap2.data->>'preferredUsername' = c.username
      WHERE ap2.local = true
        AND ap2.data->>'type' IN ('Person', 'Group', 'Organization', 'Service', 'Application')
        AND (ap2.pointer_id IS NULL OR ap2.pointer_id != c.id)
        AND NOT EXISTS (
          SELECT 1 FROM ap_object other
          WHERE other.pointer_id = c.id AND other.id != ap2.id
        )
      ORDER BY c.id, ap2.id
    ) m
    WHERE ap.id = m.ap_id
    """)
    |> then(&{&1.num_rows, nil})
  end
end
