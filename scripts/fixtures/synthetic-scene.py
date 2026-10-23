"""Render a small synthetic multi-view fixture for CPU-only SfM smoke tests.

The repository ships no image fixtures, so the AMD validation needs a
deterministic image set with real perspective parallax. Blender renders a
noise-textured object cluster from an orbiting camera; COLMAP then has enough
high-frequency detail for CPU SIFT without any downloaded dataset.

Usage:
  blender --background --python scripts/fixtures/synthetic-scene.py -- <output-dir>
  (optional third argument overrides the view count, default 16)
"""
import math
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_dir = os.path.abspath(argv[0]) if argv else os.path.abspath("synthetic-images")
views = int(argv[1]) if len(argv) > 1 else 16
radius = 3.6
height = 1.5

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 32
scene.cycles.use_denoising = False
scene.render.resolution_x = 640
scene.render.resolution_y = 480
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False


def noise_material(name, scale, low, high):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    shader = nodes["Principled BSDF"]
    shader.inputs["Roughness"].default_value = 0.8
    texture = nodes.new("ShaderNodeTexNoise")
    texture.inputs["Scale"].default_value = scale
    texture.inputs["Detail"].default_value = 14.0
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*low, 1.0)
    ramp.color_ramp.elements[1].color = (*high, 1.0)
    links.new(texture.outputs["Fac"], ramp.inputs["Fac"])
    # A second, much finer octave keeps SIFT fed at every viewing distance.
    grain = nodes.new("ShaderNodeTexNoise")
    grain.inputs["Scale"].default_value = scale * 4.0
    grain.inputs["Detail"].default_value = 8.0
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 0.55
    links.new(ramp.outputs["Color"], mix.inputs[6])
    links.new(grain.outputs["Color"], mix.inputs[7])
    links.new(mix.outputs[2], shader.inputs["Base Color"])
    return material


def checker_material(name, scale):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    texture = nodes.new("ShaderNodeTexChecker")
    texture.inputs["Scale"].default_value = scale
    links.new(texture.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    return material


def add(primitive, location, scale, material, **kwargs):
    primitive(location=location, **kwargs)
    obj = bpy.context.active_object
    obj.scale = scale
    obj.data.materials.append(material)
    return obj


floor = checker_material("floor", 6.0)
warm = noise_material("warm", 70.0, (0.05, 0.02, 0.02), (0.9, 0.55, 0.15))
cool = noise_material("cool", 90.0, (0.02, 0.05, 0.12), (0.35, 0.75, 0.95))
bright = noise_material("bright", 130.0, (0.5, 0.5, 0.5), (1.0, 1.0, 1.0))

add(bpy.ops.mesh.primitive_plane_add, (0.0, 0.0, 0.0), (4.0, 4.0, 4.0), floor, size=1.0)
add(bpy.ops.mesh.primitive_monkey_add, (0.0, 0.0, 1.05), (1.1, 1.1, 1.1), warm)
add(bpy.ops.mesh.primitive_torus_add, (-1.35, 0.75, 0.75), (0.7, 0.7, 0.7), cool, major_radius=0.85, minor_radius=0.28)
add(bpy.ops.mesh.primitive_cube_add, (1.35, -0.7, 0.55), (0.55, 0.55, 0.55), bright)
add(bpy.ops.mesh.primitive_cone_add, (1.15, 1.15, 0.65), (0.5, 0.5, 0.65), warm)
add(bpy.ops.mesh.primitive_cylinder_add, (-1.45, -1.05, 0.5), (0.4, 0.4, 0.5), cool)
add(bpy.ops.mesh.primitive_uv_sphere_add, (0.0, -1.5, 0.45), (0.45, 0.45, 0.45), bright)

sun_data = bpy.data.lights.new("sun", type="SUN")
sun_data.energy = 3.0
sun = bpy.data.objects.new("sun", sun_data)
sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(60))
scene.collection.objects.link(sun)
scene.world = bpy.data.worlds.new("world")
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.25, 0.28, 0.32, 1.0)
scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.7

target = bpy.data.objects.new("target", None)
target.location = (0.0, 0.0, 0.8)
scene.collection.objects.link(target)
camera_data = bpy.data.cameras.new("camera")
camera_data.lens = 32.0
camera = bpy.data.objects.new("camera", camera_data)
scene.collection.objects.link(camera)
track = camera.constraints.new("TRACK_TO")
track.target = target
track.track_axis = "TRACK_NEGATIVE_Z"
track.up_axis = "UP_Y"
scene.camera = camera

os.makedirs(out_dir, exist_ok=True)
for index in range(views):
    angle = 2.0 * math.pi * index / views
    camera.location = (radius * math.cos(angle), radius * math.sin(angle), height)
    scene.render.filepath = os.path.join(out_dir, "view-%03d.png" % index)
    bpy.ops.render.render(write_still=True)
    print("rendered", scene.render.filepath)
