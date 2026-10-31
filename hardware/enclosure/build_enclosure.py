"""Blender-native, millimetre-scale ESP32 DevKitC V4 enclosure.

Run: blender --background --python build_enclosure.py -- --output /path/to/output
All meshes are generated from dimensions; no reference-image geometry is traced.
"""
import argparse
import json
import math
from pathlib import Path
import sys

import bmesh
import bpy
from mathutils import Vector


parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--pin-hole", type=float, default=0.95, help="Square passage side, mm")
parser.add_argument("--light-x", type=float, default=-22.7, help="Provisional LED aperture X, mm")
parser.add_argument("--light-y", type=float, default=-5.4, help="Provisional LED aperture Y, mm")
parser.add_argument("--render", action="store_true")
args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)

# Official Espressif drawing: PCB 48.26 x 27.94, 19 pins per row,
# 25.40 row separation, 2.54 pitch, 1.29 from USB PCB edge to first pin.
PCB_L, PCB_W, PCB_T = 48.26, 27.94, 1.60
PCB_X = -4.50
ROW_Y = (PCB_W / 2 - 1.30 - 25.40, PCB_W / 2 - 1.30)
PIN_X = [PCB_X - PCB_L / 2 + 1.29 + i * 2.54 for i in range(19)]
L, W, H, R = 66.80, 42.80, 17.20, 10.0
WALL, FLOOR, SEAM = 2.20, 2.20, 11.80
SEAT_Z = 4.80
LIP_CLEARANCE, LIP_WALL, LIP_DEPTH = 0.20, 1.60, 2.80

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.length_unit = "MILLIMETERS"
scene.unit_settings.scale_length = 0.001


def material(name, color, roughness=0.5, metal=0):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    node = mat.node_tree.nodes.get("Principled BSDF")
    node.inputs["Base Color"].default_value = (*color, 1)
    node.inputs["Roughness"].default_value = roughness
    node.inputs["Metallic"].default_value = metal
    return mat


olive = material("Matte olive PETG", (0.13, 0.19, 0.13), 0.7)
black = material("Header plastic", (0.025, 0.03, 0.025), 0.6)
pcb_green = material("PCB reference only", (0.03, 0.10, 0.065), 0.6)
silver = material("Metal reference only", (0.46, 0.48, 0.47), 0.3, 0.75)
gold = material("Pin reference only", (0.55, 0.36, 0.09), 0.3, 0.7)


def rounded_outline(length, width, radius, segments=16):
    points = []
    for cx, cy, start in [(length/2-radius, width/2-radius, 0),
                           (-length/2+radius, width/2-radius, 90),
                           (-length/2+radius, -width/2+radius, 180),
                           (length/2-radius, -width/2+radius, 270)]:
        for i in range(segments):
            angle = math.radians(start + 90 * i / (segments - 1))
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def mesh_object(name, vertices, faces):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    return obj


def loft(name, rings):
    n = len(rings[0])
    vertices = [p for ring in rings for p in ring]
    faces = [tuple(reversed(range(n)))]
    for j in range(len(rings) - 1):
        a, b = j*n, (j+1)*n
        faces.extend((a+i, a+(i+1)%n, b+(i+1)%n, b+i) for i in range(n))
    faces.append(tuple(range((len(rings)-1)*n, len(rings)*n)))
    return mesh_object(name, vertices, faces)


def round_loft(name, levels):
    return loft(name, [[(x, y, z) for x, y in rounded_outline(l, w, r)] for z, l, w, r in levels])


def box(name, size, location, bevel=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = obj.modifiers.new("Printed edge radius", "BEVEL")
        mod.width = bevel
        mod.segments = 5
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def boolean(target, cutter, operation="DIFFERENCE"):
    bpy.context.view_layer.objects.active = target
    mod = target.modifiers.new(operation, "BOOLEAN")
    mod.operation = operation
    mod.solver = "EXACT"
    mod.object = cutter
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def combine_cutters(name, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    result = bpy.context.object
    result.name = name
    return result


def pin_cutters(centers, hole, floor=FLOOR):
    cutters = []
    for i, (x, y) in enumerate(centers):
        # The upper 0.55 mm is a lead-in; the rest locates a nominal 0.64 mm square pin.
        rings = []
        for z, side in [(-0.4, hole), (floor-0.55, hole), (floor+0.02, hole+0.65), (floor+0.4, hole+0.65)]:
            rings.append([(x+a*side/2, y+b*side/2, z) for a, b in [(-1,-1),(1,-1),(1,1),(-1,1)]])
        cutters.append(loft(f"Pin passage {i+1}", rings))
    return combine_cutters("All pin passage cutters", cutters)


base_levels = []
for index in range(10):
    angle = math.pi/2 * index/9
    inset = 1.5*(1-math.sin(angle))
    base_levels.append((1.5*(1-math.cos(angle)), L-2*inset, W-2*inset, R-inset))
base_levels.append((SEAM, L, W, R))
base = round_loft("EWP Base - PRINT", base_levels)
inside_l, inside_w, inside_r = L-2*WALL, W-2*WALL, R-WALL
boolean(base, round_loft("Open interior", [(FLOOR, inside_l, inside_w, inside_r),
                                          (SEAM+2, inside_l, inside_w, inside_r)]))
for x in [PCB_X-12, PCB_X+12]:
    for y in [-9.70, 9.70]:
        # Insulating seats are inside the header rows, clear of the plastic housings.
        boolean(base, box("PCB edge seat", (5.8, 1.55, SEAT_Z-FLOOR+0.25),
                          (x, y, (FLOOR+SEAT_Z)/2-0.125), 0.25), "UNION")
boolean(base, pin_cutters([(x, y) for y in ROW_Y for x in PIN_X], args.pin_hole))

lid_levels = [(SEAM, L-0.1, W-0.1, R-0.05)]
for index in range(13):
    angle = math.pi/2 * index/12
    inset = 3.2*(1-math.cos(angle))
    lid_levels.append((H-3.2+3.2*math.sin(angle), L-0.1-2*inset, W-0.1-2*inset, R-0.05-inset))
lid = round_loft("EWP Lid - PRINT", lid_levels)
boolean(lid, round_loft("Lid underside", [(SEAM-1, inside_l-2*LIP_CLEARANCE-2*LIP_WALL+0.1, inside_w-2*LIP_CLEARANCE-2*LIP_WALL+0.1, inside_r-LIP_CLEARANCE-LIP_WALL+0.05),
                                         (H-2.6, inside_l-2*LIP_CLEARANCE-2*LIP_WALL+0.1, inside_w-2*LIP_CLEARANCE-2*LIP_WALL+0.1, inside_r-LIP_CLEARANCE-LIP_WALL+0.05)]))
lip_l, lip_w, lip_r = inside_l-2*LIP_CLEARANCE, inside_w-2*LIP_CLEARANCE, inside_r-LIP_CLEARANCE
lip = round_loft("Lid registration lip", [(SEAM-LIP_DEPTH, lip_l-0.5, lip_w-0.5, lip_r-0.25),
                                          (SEAM-LIP_DEPTH+0.5, lip_l, lip_w, lip_r),
                                          (SEAM+0.4, lip_l, lip_w, lip_r)])
boolean(lip, round_loft("Lip inside", [(SEAM-LIP_DEPTH-1, lip_l-2*LIP_WALL, lip_w-2*LIP_WALL, lip_r-LIP_WALL),
                                      (SEAM+1, lip_l-2*LIP_WALL, lip_w-2*LIP_WALL, lip_r-LIP_WALL)]))
boolean(lid, lip, "UNION")
for x in [-15, 15]:
    for side in [-1, 1]:
        # Four rounded ribs create 0.075 mm nominal interference against the base.
        boolean(lid, box("Lid friction rib", (4.5, 0.65, 1.7),
                         (x, side*(lip_w/2-0.05), SEAM-1.6), 0.20), "UNION")

for part in [base, lid]:
    # A moulded cable can enter the recess; not just the bare metal connector.
    boolean(part, box("Micro USB cable access", (15, 14, 8.4), (-32.0, 0, 8.25), 1.2))
    part.data.materials.append(olive)

bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.8, depth=10,
                                  location=(args.light_x, args.light_y, H-1))
boolean(lid, bpy.context.object)

# A complete grid coupon checks both header rows and all 19 positions before a long print.
coupon = box("38 pin fit coupon - PRINT", (51.5, 29.8, FLOOR), (PCB_X, 0, FLOOR/2), 0.5)
boolean(coupon, pin_cutters([(x, y) for y in ROW_Y for x in PIN_X], args.pin_hole))
coupon.data.materials.append(olive)

mini_coupons = []
for hole in [0.85, 0.95, 1.05]:
    part = box(f"Tolerance coupon {hole:.2f} - PRINT", (12, 29.8, FLOOR), (0, 0, FLOOR/2), 0.4)
    boolean(part, pin_cutters([(x, y) for y in ROW_Y for x in [-3.81, -1.27, 1.27, 3.81]], hole))
    part.data.materials.append(olive)
    mini_coupons.append(part)

# Reference envelope is visible in the editable file, excluded from STL exports.
reference = bpy.data.collections.new("REFERENCE ONLY - verify against your board")
scene.collection.children.link(reference)


def ref(obj, mat):
    for collection in list(obj.users_collection):
        collection.objects.unlink(obj)
    reference.objects.link(obj)
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.material_index = 0
    obj.hide_render = True
    return obj


ref(box("PCB 48.26 x 27.94 x 1.60 - reference", (PCB_L, PCB_W, PCB_T),
        (PCB_X, 0, SEAT_Z+PCB_T/2)), pcb_green)
ref(box("Antenna overhang 6.04 - reference", (6.04, 18, 1),
        (PCB_X+PCB_L/2+3.02, 0, SEAT_Z+PCB_T+2)), pcb_green)
ref(box("WROOM module approximate height - verify", (19.5, 18, 3.2),
        (PCB_X+10.7, 0, SEAT_Z+PCB_T+1.6)), silver)
ref(box("Micro USB envelope - verify", (5.8, 7.8, 2.7),
        (PCB_X-PCB_L/2+1.7, 0, SEAT_Z+PCB_T+1.35)), silver)
for y in ROW_Y:
    ref(box("Header housing reference", (48.26, 2.54, 2.5),
            (sum(PIN_X)/19, y, SEAT_Z-1.25)), black)
    for x in PIN_X:
        ref(box("0.64 square header pin reference", (0.64, 0.64, 6), (x, y, SEAT_Z-5.5)), gold)


def validate(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    non_manifold = sum(not e.is_manifold for e in bm.edges)
    volume = bm.calc_volume(signed=True)
    remaining = set(bm.verts)
    components = 0
    while remaining:
        components += 1
        pending = [remaining.pop()]
        while pending:
            vertex = pending.pop()
            for edge in vertex.link_edges:
                other = edge.other_vert(vertex)
                if other in remaining:
                    remaining.remove(other)
                    pending.append(other)
    bm.free()
    if non_manifold or volume <= 0 or components != 1:
        raise RuntimeError(f"{obj.name}: non-manifold edges={non_manifold}, connected components={components}, volume={volume}")
    return {"name": obj.name, "non_manifold_edges": non_manifold,
            "connected_components": components, "volume_mm3": round(volume, 3), "dimensions_mm": [round(v, 3) for v in obj.dimensions]}


reports = []
for obj, filename in [(base, "ewp-devkitc-v4-base.stl"), (lid, "ewp-devkitc-v4-lid.stl"),
                       (coupon, "ewp-devkitc-v4-pin-fit-test.stl")] + [
                           (part, f"ewp-pin-tolerance-{hole:.2f}.stl") for part, hole in zip(mini_coupons, [0.85,0.95,1.05])]:
    obj.data.materials.clear()
    obj.data.materials.append(olive)
    for polygon in obj.data.polygons:
        polygon.material_index = 0
        polygon.use_smooth = max(abs(v) for v in polygon.normal) < 0.9999
    reports.append(validate(obj))
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    # Print each part on its broad flat face; the lid is inverted for export.
    old_matrix = obj.matrix_world.copy()
    if obj == lid:
        obj.rotation_euler.x = math.pi
        obj.location.z = H
    bpy.ops.wm.stl_export(filepath=str(out/filename), export_selected_objects=True,
                          global_scale=1.0, apply_modifiers=True, use_scene_unit=False)
    obj.matrix_world = old_matrix

(out/"geometry-checks.json").write_text(json.dumps({
    "units": "mm", "pin_count": 38, "pin_pitch": 2.54, "row_spacing": 25.40,
    "pin_hole_square_side": args.pin_hole, "case_dimensions": [L, W, H],
    "led_hole_diameter": 1.6, "led_position_provisional": [args.light_x, args.light_y],
    "physical_fit_verified": False, "parts": reports}, indent=2))

# Keep the board reference assembled, and display the removable lid beside the base.
for obj in [coupon]+mini_coupons:
    obj.hide_set(True)
    obj.hide_render = True
base.location = (-22, -10, 0)
lid.location = (26, 14, 0)
for obj in reference.objects:
    obj.location += Vector((-22, -10, 0))
    obj.hide_set(True)

world = scene.world or bpy.data.worlds.new("Studio")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.73, 0.73, 0.70, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.5
ground_mat = material("Warm studio background", (0.72, 0.68, 0.59), 0.85)
ground = box("Studio floor - not for printing", (400, 400, 1), (0,0,-1))
ground.data.materials.append(ground_mat)


def aim(obj, point):
    obj.rotation_euler = (Vector(point)-obj.location).to_track_quat("-Z", "Y").to_euler()


bpy.ops.object.camera_add(location=(-105, -150, 145))
camera = bpy.context.object
camera.name = "Product camera"
camera.data.type = "ORTHO"
camera.data.ortho_scale = 145
camera.data.lens = 55
camera.data.clip_start = 0.1
camera.data.clip_end = 2000
aim(camera, (0, 0, 7))
scene.camera = camera
for name, pos, energy, size in [("Softbox", (-60,-80,150), 900, 100),
                                ("Fill", (70,40,100), 500, 80), ("Rim", (-20,100,80), 600, 70)]:
    bpy.ops.object.light_add(type="AREA", location=pos)
    light = bpy.context.object
    light.name = name
    light.data.energy = energy * 100
    light.data.shape = "DISK"
    light.data.size = size
    aim(light, (0,0,5))
scene.render.engine = "CYCLES"
scene.cycles.samples = 48
scene.render.resolution_x = 1600
scene.render.resolution_y = 1100
scene.render.resolution_percentage = 100
scene.view_settings.view_transform = "AgX"
# Make the editable file open with both parts framed, without studio clutter.
bpy.ops.object.select_all(action="DESELECT")
for obj in [base, lid]:
    obj.select_set(True)
bpy.context.view_layer.objects.active = base
for obj in scene.objects:
    if obj.type in {"LIGHT", "CAMERA"} or obj == ground:
        obj.hide_set(True)
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == "VIEW_3D":
            space = area.spaces.active
            space.clip_start, space.clip_end = 0.1, 2000
            space.shading.type = "SOLID"
            space.shading.color_type = "MATERIAL"
            space.shading.show_cavity = True
            space.overlay.show_floor = False
            space.region_3d.view_location = (0, 0, 7)
            space.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
            space.region_3d.view_distance = 155
            space.region_3d.view_perspective = "ORTHO"
bpy.ops.wm.save_as_mainfile(filepath=str(out/"ewp-devkitc-v4.blend"))
if args.render:
    scene.render.filepath = str(out/"ewp-enclosure-open.png")
    bpy.ops.render.render(write_still=True)
    # Assembled exterior: no screen, one small light aperture.
    base.location = (0,0,0)
    lid.location = (0,0,0)
    camera.location = (-85,-100,100)
    camera.data.ortho_scale = 90
    aim(camera, (0,0,7))
    scene.render.filepath = str(out/"ewp-enclosure-assembled.png")
    bpy.ops.render.render(write_still=True)
    lid.hide_render = True
    ground.hide_render = True
    camera.location = (-45,-65,-100)
    camera.data.ortho_scale = 98
    aim(camera, (0,0,2))
    bpy.ops.object.light_add(type="AREA", location=(0,-40,-80))
    bpy.context.object.data.energy = 50000
    bpy.context.object.data.size = 80
    aim(bpy.context.object, (0,0,0))
    scene.render.filepath = str(out/"ewp-enclosure-underside.png")
    bpy.ops.render.render(write_still=True)
print("EWP enclosure exported; topology validated. Physical fit awaits board measurements and a test print.")
