using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Builds trimesh collision for every mesh below this node, when asked to.
///
/// This exists because collision on the props is per-instance in Unity, not
/// per-model. Every prop .fbx.meta says addColliders: 0; the colliders are
/// MeshCollider components added to individual instances in nivelEscena, so two
/// instances of the same model can disagree about whether they are solid. Of the
/// four tablePcs clusters exactly one has them - the desk beside the player's
/// spawn - and the other three are walk-through. Import-time physics cannot
/// express that: it would make all four solid.
///
/// Off by default, so an instance is only solid where Unity said it was. Set
/// GenerateCollision on that instance in the scene that places it.
///
/// Runtime only, and deliberately not [Tool]. Generating in the editor would add
/// a StaticBody3D per mesh every time the scene loads and save them with it -
/// the same reason LevelShell builds its 53 bodies at runtime.
/// </summary>
public partial class PropCollision : Node3D
{
    /// <summary>
    /// Whether this instance is solid. Default false: Unity's colliders sat on
    /// specific instances, so silence has to mean walk-through.
    /// </summary>
    [Export]
    public bool GenerateCollision { get; set; }

    public override void _Ready()
    {
        if (!GenerateCollision)
        {
            return;
        }

        int built = 0;
        foreach (MeshInstance3D mesh in FindMeshes(this))
        {
            mesh.CreateTrimeshCollision();
            built++;
        }

        // Worth surfacing: a cluster that silently builds nothing means the model
        // tree changed shape under the scene, and the prop is quietly passable.
        if (built == 0)
        {
            GD.PushWarning($"{Name}: GenerateCollision is set but no meshes were found below it; this prop is not solid.");
        }
        else
        {
            GD.Print($"{Name}: built trimesh collision for {built} meshes.");
        }
    }

    private static Godot.Collections.Array<MeshInstance3D> FindMeshes(Node node)
    {
        var found = new Godot.Collections.Array<MeshInstance3D>();
        if (node is MeshInstance3D mesh)
        {
            found.Add(mesh);
        }

        foreach (Node child in node.GetChildren())
        {
            foreach (MeshInstance3D nested in FindMeshes(child))
            {
                found.Add(nested);
            }
        }

        return found;
    }
}
