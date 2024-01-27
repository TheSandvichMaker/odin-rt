package rt

import "core:math"
import "core:slice"
import sm "core:container/small_array"

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

    was_modified : bool,

    sun        : Directional_Light,
    materials  : [dynamic]Material,
    spheres    : [dynamic]Sphere,
    planes     : [dynamic]Plane,
    boxes      : [dynamic]Box,
    bvh        : BVH, // TODO: figure this out
    primitives : [dynamic]Primitive_Holder,
}

scene_modified :: proc(scene: ^Scene)
{
    scene.was_modified = true
}

copy_into_array :: proc(dst: ^[dynamic]$T, src: []T)
{
    resize(dst, len(src))
    copy_slice(dst[:], src)
}

deep_copy_scene :: proc(dst: ^Scene, src: ^Scene)
{
    dst.sun = src.sun

    copy_into_array(&dst.materials,  src.materials[:])
    copy_into_array(&dst.spheres,    src.spheres[:])
    copy_into_array(&dst.planes,     src.planes[:])
    copy_into_array(&dst.boxes,      src.boxes[:])
    dst.bvh = src.bvh // TODO: figure this out
    dst.primitives = src.primitives
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

Ray_Debug_Info :: struct
{
    nodes_tried          : [dynamic]u32,
    nodes_hit            : [dynamic]u32,
    nodes_missed         : [dynamic]u32,
    closest_hit_node     : u32,
}

@(require_results)
intersect_scene_accelerated_impl :: proc(
    scene             : ^Scene, 
    ray               : Ray, 
    $EARLY_OUT        : bool, 
    $WRITE_DEBUG_INFO : bool, 
    debug             : ^Ray_Debug_Info) -> (result: ^Primitive, t: f32)
{
    bvh := &scene.bvh

    stack: sm.Small_Array(32, u32)
    sm.push_back(&stack, 0)

    ray := ray
    t = ray.t_max

    for sm.len(stack) > 0
    {
        node_index := sm.pop_back(&stack)
        node       := &bvh.nodes[node_index]

        when WRITE_DEBUG_INFO
        {
            append(&debug.nodes_tried, node_index)
        }

        if ok, _ := intersect_box_simple(ray, node.bounds.min, node.bounds.max); ok
        {
            when WRITE_DEBUG_INFO
            {
                append(&debug.nodes_hit, node_index)
            }

            if node.count > 0
            {
                first := node.left_or_first
                count := node.count

                for i := first; i < first + count; i += 1
                {
                    primitive_index := bvh.indices[i]
                    holder          := &scene.primitives[primitive_index]
                    primitive       := &holder.primitive

                    hit, hit_t := intersect_primitive(primitive, ray)

                    if hit && hit_t <= t
                    {
                        result    = primitive
                        t         = hit_t
                        ray.t_max = t

                        when WRITE_DEBUG_INFO
                        {
                            debug.closest_hit_node = node_index
                        }

                        when EARLY_OUT
                        {
                            return result, t
                        }
                    }
                }
            }
            else
            {
                left  := node.left_or_first
                right := left + 1
                sm.push_back(&stack, left)
                sm.push_back(&stack, right)
            }
        }
        else
        {
            when WRITE_DEBUG_INFO
            {
                append(&debug.nodes_missed, node_index)
            }
        }
    }

    // do planes as well...
    for &plane, plane_index in scene.planes
    {
        hit, hit_t := intersect_plane(&plane, ray)
        if hit && hit_t < t
        {
            result = &plane
            t      = hit_t

            when EARLY_OUT
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
    return intersect_scene_accelerated_impl(scene, ray, false, false, nil)
}

@(require_results)
intersect_scene_shadow :: proc(scene: ^Scene, ray: Ray) -> bool
{
    primitive, t := intersect_scene_accelerated_impl(scene, ray, true, false, nil)
    return primitive != nil
}

@(require_results)
intersect_scene_brute_force_impl :: proc(scene: ^Scene, ray: Ray, $early_out: bool) -> (^Primitive, f32)
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
        min := box.p - box.r
        max := box.p + box.r
        hit, hit_t := intersect_box_simple(ray, min, max)
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
intersect_scene_brute_force :: proc(scene: ^Scene, ray: Ray) -> (^Primitive, f32)
{
    return intersect_scene_brute_force_impl(scene, ray, false)
}

@(require_results)
intersect_scene_shadow_brute_force :: proc(scene: ^Scene, ray: Ray) -> bool
{
    primitive, t := intersect_scene_brute_force_impl(scene, ray, true)
    return primitive != nil
}
