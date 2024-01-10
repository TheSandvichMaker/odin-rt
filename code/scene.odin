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
    return &scene.spheres[index]
}

@(require_results)
intersect_scene :: proc(scene: ^Scene, ray: Ray) -> (^Sphere, f32)
{
    result: ^Sphere

    t: f32 = math.F32_MAX

    for &sphere, sphere_index in scene.spheres
    {
        hit, hit_t := intersect_sphere(&sphere, ray)
        if hit && hit_t < t
        {
            result = &sphere
            t      = hit_t
        }
    }

    return result, t
}
