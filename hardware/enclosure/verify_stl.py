"""Check the delivered binary STLs independently of Blender. Standard library only."""
from collections import Counter, defaultdict
from pathlib import Path
import struct


def read_triangles(path):
    data = path.read_bytes()
    count, = struct.unpack_from("<I", data, 80)
    assert len(data) == 84 + 50*count, f"{path.name}: malformed binary STL"
    for i in range(count):
        values = struct.unpack_from("<12fH", data, 84+50*i)
        yield tuple(tuple(round(x, 5) for x in values[j:j+3]) for j in [3, 6, 9])


def components(adjacency):
    unseen = set(adjacency)
    count = 0
    while unseen:
        count += 1
        todo = [unseen.pop()]
        while todo:
            for neighbour in adjacency[todo.pop()]:
                if neighbour in unseen:
                    unseen.remove(neighbour)
                    todo.append(neighbour)
    return count


def check(path, expected_holes=None):
    triangles = list(read_triangles(path))
    edges, winding = Counter(), Counter()
    adjacency = defaultdict(set)
    sections = {z: defaultdict(set) for z in [0.6, 1.8]}
    volume = 0
    for a, b, c in triangles:
        assert len({a, b, c}) == 3, f"{path.name}: collapsed triangle"
        volume += (a[0]*(b[1]*c[2]-b[2]*c[1]) - a[1]*(b[0]*c[2]-b[2]*c[0])
                   + a[2]*(b[0]*c[1]-b[1]*c[0]))/6
        crossings = {z: [] for z in sections}
        for u, v in [(a, b), (b, c), (c, a)]:
            edge = tuple(sorted((u, v)))
            edges[edge] += 1
            winding[edge] += 1 if u < v else -1
            adjacency[u].add(v)
            adjacency[v].add(u)
            # Below and above the blind socket bottoms, independently of Blender.
            for z in sections:
                if (u[2]-z)*(v[2]-z) < 0:
                    t = (z-u[2])/(v[2]-u[2])
                    crossings[z].append(tuple(round(u[i]+t*(v[i]-u[i]), 4) for i in [0, 1]))
        for z, crossing in crossings.items():
            if len(crossing) == 2 and crossing[0] != crossing[1]:
                sections[z][crossing[0]].add(crossing[1])
                sections[z][crossing[1]].add(crossing[0])
    assert all(n == 2 for n in edges.values()), f"{path.name}: open or non-manifold edge"
    assert all(n == 0 for n in winding.values()), f"{path.name}: inconsistent winding"
    assert components(adjacency) == 1, f"{path.name}: disconnected solids"
    assert volume > 0, f"{path.name}: inverted shell"
    vertices = list(adjacency)
    minimum = [min(v[i] for v in vertices) for i in range(3)]
    maximum = [max(v[i] for v in vertices) for i in range(3)]
    assert abs(minimum[2]) < 0.001, f"{path.name}: not seated on print bed"
    if expected_holes is not None:
        for section in sections.values():
            assert all(len(n) == 2 for n in section.values()), f"{path.name}: open section"
        assert components(sections[0.6]) == 1, f"{path.name}: socket breaks through underside"
        assert components(sections[1.8]) == expected_holes+1, f"{path.name}: wrong blind socket count"
    dimensions = tuple(round(maximum[i]-minimum[i], 3) for i in range(3))
    print(f"{path.name}: watertight, one solid, {len(triangles)} triangles, {dimensions} mm"
          + (f", {expected_holes} blind sockets, solid underside" if expected_holes is not None else ""))


if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    expected = {"ewp-devkitc-v4-base.stl": 38, "ewp-devkitc-v4-lid.stl": None,
                "ewp-devkitc-v4-pin-fit-test.stl": 38,
                **{f"ewp-pin-tolerance-{n:.2f}.stl": 8 for n in [0.85, 0.95, 1.05]}}
    for name, holes in expected.items():
        check(root/name, holes)
