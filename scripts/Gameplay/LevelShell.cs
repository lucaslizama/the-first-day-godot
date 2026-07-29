using System.Collections.Generic;
using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Applies the level shell's per-surface materials and builds its collision.
///
/// Two things make this a script rather than import settings.
///
/// Materials: Unity assigned them per renderer-slot, not per FBX material name,
/// and the same name resolves differently in different places. lambert1 is
/// mat_generalTransparencia on nivel's pPlane meshes but mat_general on its
/// polySurface slot 1, and nivel_p2 reverses the polySurface mapping entirely.
/// Godot's importer keys external materials by name, so it cannot express that.
/// The real assignment was read out of nivelEscena's prefab-instance overrides
/// and lives in level_materials.json - 74 renderer-slot entries across the two
/// models.
///
/// Collision: 53 mesh instances would need 53 _subresources entries in the
/// .import file to generate bodies at import time. One create_trimesh_collision
/// call each is less to get wrong, and keeps the .import files readable.
/// </summary>
public partial class LevelShell : Node3D
{
    /// <summary>Maps mesh node name to a slot-index -> material path table.</summary>
    [Export(PropertyHint.File, "*.json")]
    public string MaterialTablePath { get; set; } = "res://models/level/level_materials.json";

    /// <summary>Key into the table, e.g. "nivel.fbx". Selects this shell's section.</summary>
    [Export]
    public string ModelKey { get; set; } = "";

    [Export]
    public bool GenerateCollision { get; set; } = true;

    public override void _Ready()
    {
        Dictionary<string, Dictionary<int, string>> table = LoadTable();
        int applied = 0;
        int collided = 0;

        // Tracks which table entries actually found a mesh. Without this, an entry
        // naming a node that is not a MeshInstance3D silently does nothing - which
        // is exactly what happened with pPlane30: Unity had a renderer on it, but
        // Godot imports it as a plain Node3D whose polySurface children carry the
        // geometry. Warning only about unmapped meshes, and not about unused
        // entries, hid that entirely.
        var matched = new HashSet<string>();

        foreach (MeshInstance3D mesh in FindMeshes(this))
        {
            matched.Add(mesh.Name);

            if (table.TryGetValue(mesh.Name, out Dictionary<int, string>? slots))
            {
                foreach ((int slot, string path) in slots)
                {
                    if (slot >= mesh.Mesh.GetSurfaceCount())
                    {
                        GD.PushWarning($"{Name}: {mesh.Name} has no surface {slot}; the mesh and the table disagree.");
                        continue;
                    }

                    var material = ResourceLoader.Load<Material>(path);
                    if (material is null)
                    {
                        GD.PushError($"{Name}: could not load '{path}' for {mesh.Name} slot {slot}.");
                        continue;
                    }

                    mesh.SetSurfaceOverrideMaterial(slot, material);
                    applied++;
                }
            }
            else
            {
                // Worth surfacing rather than silently leaving the Maya material on:
                // an unmapped mesh renders with lambert1/lambert2 and looks wrong.
                GD.PushWarning($"{Name}: no material entry for mesh '{mesh.Name}'; it keeps its imported material.");
            }

            if (GenerateCollision)
            {
                mesh.CreateTrimeshCollision();
                collided++;
            }
        }

        foreach (string entry in table.Keys)
        {
            if (matched.Contains(entry))
            {
                continue;
            }

            // Distinguish the two ways an entry can go unused. A name that exists
            // but is not a mesh is the expected, harmless case: Unity had a
            // renderer on that node while Godot imported it as a plain parent whose
            // children hold the geometry, and those children carry their own
            // assignments. A name that is absent entirely means the table and the
            // model have genuinely diverged, which is worth a warning.
            if (FindChild(entry, recursive: true, owned: false) is Node existing)
            {
                GD.Print($"{Name}: table entry '{entry}' targets a {existing.GetType().Name}, not a mesh; its children carry their own materials. Ignored.");
            }
            else
            {
                GD.PushWarning($"{Name}: material table names '{entry}', but no node by that name exists here. The table and the imported model have diverged.");
            }
        }

        GD.Print($"{Name}: applied {applied} surface materials, built collision for {collided} meshes.");
    }

    private Dictionary<string, Dictionary<int, string>> LoadTable()
    {
        var result = new Dictionary<string, Dictionary<int, string>>();

        using FileAccess? file = FileAccess.Open(MaterialTablePath, FileAccess.ModeFlags.Read);
        if (file is null)
        {
            GD.PushError($"{Name}: cannot open material table '{MaterialTablePath}'.");
            return result;
        }

        var json = new Json();
        if (json.Parse(file.GetAsText()) != Error.Ok)
        {
            GD.PushError($"{Name}: {MaterialTablePath} is not valid JSON: {json.GetErrorMessage()} (line {json.GetErrorLine()}).");
            return result;
        }

        if (json.Data.AsGodotDictionary() is not Godot.Collections.Dictionary root)
        {
            return result;
        }

        if (!root.ContainsKey(ModelKey))
        {
            GD.PushError($"{Name}: material table has no section '{ModelKey}'. Set ModelKey to one of its top-level keys.");
            return result;
        }

        var section = root[ModelKey].AsGodotDictionary();
        foreach (Variant meshName in section.Keys)
        {
            var slots = new Dictionary<int, string>();
            var entries = section[meshName].AsGodotDictionary();
            foreach (Variant slot in entries.Keys)
            {
                slots[slot.AsString().ToInt()] = entries[slot].AsString();
            }

            result[meshName.AsString()] = slots;
        }

        return result;
    }

    private static List<MeshInstance3D> FindMeshes(Node node)
    {
        var found = new List<MeshInstance3D>();
        if (node is MeshInstance3D mesh)
        {
            found.Add(mesh);
        }

        foreach (Node child in node.GetChildren())
        {
            found.AddRange(FindMeshes(child));
        }

        return found;
    }
}
