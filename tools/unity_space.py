"""Converts extracted Unity transforms into Godot's space.

Why this exists
---------------
The two FBX importers read each model into local spaces that differ by exactly

    M = diag(-1, 1, 1)

Proven twice, independently:

  * tablePcs flattens table.fbx into its prefab root, so Unity stores the table's
    five planes as plain children. Their positions are Godot's imported positions
    with X negated, to five decimals on all five, with Z identical throughout.
    book.fbx's two children agree the same way. See generate_table_pcs_scene.py.
  * tools/check_mirror.gd probes every placed node in the built level for a
    surface beneath it and for contact with geometry, under all four axis
    conventions. Negating X wins every column; negating Z makes it far worse,
    which independently re-confirms the doc's Z-unchanged finding:

        convention   <0.1 m  <0.5 m    <2 m   <10 m  nothing  contact
        as placed        13       1       7      34      118       21
        -x               19      21      13      64       56       67
        -z                1       0       5      33      134        5
        -x -z             1       3       2      31      136       10

The first pass placed props at Unity's world coordinates unchanged, which is
correct for Y and Z but not for X. Because the models were already mirrored by the
importer and the placements were not, props sat mirrored relative to the shell:
doors inside walls, coworkers over holes. Conjugating the placements too puts
everything in one consistent space, and since Godot's handedness differs from
Unity's, that space renders the way Unity's did.

The rule
--------
Applied to every extracted value, by kind:

  position or offset vector   negate X
  rotation quaternion         (x, y, z, w) -> (x, -y, -z, w)
  scale, or a box size        unchanged

The quaternion rule is M R M expressed on quaternions, and it is the whole rule -
not a 180 degree turn about Y, which would negate Z as well and is what the table
above rules out. Checks: rotY(t) -> rotY(-t), rotZ(t) -> rotZ(-t), rotX(t)
unchanged. Scale is untouched because M S M = S for diagonal S, so props keep the
handedness Unity gave them and mirrored props stay mirrored.

Do not apply this twice. It is applied once, here, at the point where extracted
Unity data becomes input for the Godot scene generators, so every generator
downstream needs no mirror logic of its own. generate_table_pcs_scene.py is the
exception and does its own conjugation, because its numbers are prefab-local
rather than world and never pass through here.
"""

# Keys holding a position or an offset in a parent's space: X negates.
POSITION_KEYS = frozenset({"pos", "local", "center"})

# Keys holding a rotation quaternion in xyzw order.
ROTATION_KEYS = frozenset({"rot"})

# Keys deliberately left alone, listed so that adding a new key to an extractor
# without classifying it here fails loudly instead of silently passing through.
UNCHANGED_KEYS = frozenset({
    "scale", "size", "name", "kind", "prefab", "source", "box", "checkpoints",
    "coworkers", "whispers", "kill_volume", "trigger_zones", "player",
    "minDistance", "maxMinDistance", "is_trigger_prefab", "is_trigger_overrides",
})


class UnclassifiedKey(Exception):
    """Raised when extracted data grows a key this module has no rule for."""


def conjugate_position(v):
    return [-v[0], v[1], v[2]]


def conjugate_rotation(q):
    x, y, z, w = q
    return [x, -y, -z, w]


def to_godot(obj):
    """Returns obj with every position and rotation conjugated by M.

    Walks dicts and lists. Raises UnclassifiedKey on any dict key that is neither
    classified above nor obviously structural, so a new field cannot slip through
    unmirrored and put one prop in the wrong place.
    """
    if isinstance(obj, list):
        return [to_godot(v) for v in obj]

    if not isinstance(obj, dict):
        return obj

    out = {}
    for key, value in obj.items():
        if key in POSITION_KEYS and _is_vector(value, 3):
            out[key] = conjugate_position(value)
        elif key in ROTATION_KEYS and _is_vector(value, 4):
            out[key] = conjugate_rotation(value)
        elif key in UNCHANGED_KEYS or key in POSITION_KEYS or key in ROTATION_KEYS:
            out[key] = to_godot(value)
        else:
            raise UnclassifiedKey(
                "key %r is not classified in tools/unity_space.py; decide whether it "
                "is a position, a rotation or unchanged before generating scenes" % key
            )
    return out


def _is_vector(value, length):
    return (
        isinstance(value, list)
        and len(value) == length
        and all(isinstance(v, (int, float)) for v in value)
    )
