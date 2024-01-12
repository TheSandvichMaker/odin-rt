package rt

import "core:math"

Directional_Light :: struct
{
    d     : Vector3,
    color : Vector3,
}

Scene :: struct
{
    sun       : Directional_Light,
    spheres   : [dynamic]Sphere,
    planes    : [dynamic]Plane,
    materials : [dynamic]Material,
}

add_material :: proc(scene: ^Scene, material: Material) -> Material_Index
{
    index := len(scene.materials)
    append(&scene.materials, material)
    return Material_Index(index)
}

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

@(require_results)
intersect_scene_impl :: proc(scene: ^Scene, ray: Ray, $early_out: bool) -> (^Primitive, f32)
{
    result: ^Primitive

    t: f32 = math.F32_MAX

    for &sphere, sphere_index in scene.spheres
    {
        hit, hit_t := #force_inline intersect_sphere(&sphere, ray)
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
        hit, hit_t := #force_inline intersect_plane(&plane, ray)
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

    return result, t
}

@(require_results)
intersect_scene :: proc(scene: ^Scene, ray: Ray) -> (^Primitive, f32)
{
    return #force_inline intersect_scene_impl(scene, ray, false)
}

@(require_results)
intersect_scene_shadow :: proc(scene: ^Scene, ray: Ray) -> bool
{
    primitive, t := #force_inline intersect_scene_impl(scene, ray, true)
    return primitive != nil
}
