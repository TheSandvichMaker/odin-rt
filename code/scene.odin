package rt

import "core:math"

Directional_Light :: struct
{
    d     : Vector3,
    color : Vector3,
}

Scene :: struct
{
    // TODO: separate out static and dynamic scene objects, so that I only have to copy
    // dynamic on frame dispatch.

    // Probably that will just involve sending over a per-frame TLAS

    sun       : Directional_Light,
    materials : [dynamic]Material,
    spheres   : [dynamic]Sphere,
    planes    : [dynamic]Plane,
    boxes     : [dynamic]Box,
}

copy_into_array :: proc(dst: ^[dynamic]$T, src: []T)
{
    resize(dst, len(src))
    copy_slice(dst[:], src)
}

deep_copy_scene :: proc(dst: ^Scene, src: ^Scene)
{
    dst.sun = src.sun

    copy_into_array(&dst.materials, src.materials[:])
    copy_into_array(&dst.spheres,   src.spheres[:])
    copy_into_array(&dst.planes,    src.planes[:])
    copy_into_array(&dst.boxes,     src.boxes[:])
}

add_material :: proc(scene: ^Scene, material: Material) -> Material_Index
{
    index := len(scene.materials)
    append(&scene.materials, material)
    return Material_Index(index)
}

@(require_results)
get_material :: proc(scene: ^Scene, index: Material_Index) -> ^Material
{
    return &scene.materials[index]
}

add_sphere :: proc(scene: ^Scene, sphere: Sphere) -> ^Sphere
{
    index := len(scene.spheres)
    append(&scene.spheres, sphere)

    result := &scene.spheres[index]
    result.kind = Primitive_Kind.SPHERE

    return result

}

add_plane :: proc(scene: ^Scene, plane: Plane) -> ^Plane
{
    index := len(scene.planes)
    append(&scene.planes, plane)

    result := &scene.planes[index]
    result.kind = Primitive_Kind.PLANE

    return result
}

add_box :: proc(scene: ^Scene, box: Box) -> ^Box
{
    index := len(scene.boxes)
    append(&scene.boxes, box)

    result := &scene.boxes[index]
    result.kind = Primitive_Kind.BOX

    return result
}

@(require_results)
intersect_scene_impl :: proc(scene: ^Scene, ray: Ray, $early_out: bool) -> (^Primitive, f32)
{
    result: ^Primitive

    t: f32 = math.F32_MAX

    for &sphere, sphere_index in scene.spheres
    {
        hit, hit_t := intersect_sphere(&sphere, ray)
        if hit && hit_t < t
        {
            result = &sphere
            t      = hit_t

            when early_out
            {
                return result, t
            }
        }
    }

    for &plane, plane_index in scene.planes
    {
        hit, hit_t := intersect_plane(&plane, ray)
        if hit && hit_t < t
        {
            result = &plane
            t      = hit_t

            when early_out
            {
                return result, t
            }
        }
    }

    for &box, box_index in scene.boxes
    {
        hit, hit_t := intersect_box(&box, ray)
        if hit && hit_t < t
        {
            result = &box
            t      = hit_t

            when early_out
            {
                return result, t
            }
        }
    }

    return result, t
}

@(require_results)
intersect_scene :: proc(scene: ^Scene, ray: Ray) -> (^Primitive, f32)
{
    return intersect_scene_impl(scene, ray, false)
}

@(require_results)
intersect_scene_shadow :: proc(scene: ^Scene, ray: Ray) -> bool
{
    primitive, t := intersect_scene_impl(scene, ray, true)
    return primitive != nil
}
