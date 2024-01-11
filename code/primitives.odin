package rt

import "core:math"

Material :: struct
{
    albedo         : Vector3,
    reflectiveness : f32,
}

Material_Index :: distinct u32

Primitive_Kind :: enum
{
    PLANE,
    SPHERE,
}

Primitive :: struct
{
    kind     : Primitive_Kind,
    material : Material_Index,
    p        : Vector3,
}

Sphere :: struct
{
    using base: Primitive,
    r: f32,
}

Plane :: struct
{
    using base: Primitive,
    n: Vector3,
}

@(require_results)
intersect_sphere :: proc "contextless" (sphere: ^Sphere, using ray: Ray) -> (hit: bool, t: f32)
{
    EPSILON :: 0.00001

    hit = false
    t   = math.F32_MAX

    rel_p := ro - sphere.p  // I feel like this should be the other way around...
    r_sq  := sphere.r*sphere.r

    b := dot(rd, rel_p)
    c := dot(rel_p, rel_p) - r_sq

    disc := b*b - c
    if disc >= 0.0
    {
        disc_root := math.sqrt(disc)
        tn := -b - disc_root
        tf := -b + disc_root
        test_t := tn >= 0.0 ? tn : tf
        if test_t >= t_min && test_t < t_max
        {
            hit = true
            t   = test_t
        }
    }

    return hit, t
}

@(require_results)
intersect_plane :: proc "contextless" (plane: ^Plane, using ray: Ray) -> (hit: bool, t: f32)
{
    EPSILON :: 0.00001

    hit = false
    t   = math.F32_MAX

    denom := dot(plane.n, rd)

    if denom < -EPSILON
    {
        test_t := (dot(plane.n, plane.p) - dot(plane.n, ro)) / denom
        if test_t >= t_min && test_t < t_max
        {
            hit = true
            t   = test_t
        }
    }

    return hit, t
}

@(require_results)
primitive_normal_from_hit :: proc "contextless" (primitive: ^Primitive, hit_p: Vector3) -> Vector3
{
    n: Vector3 = ---

    switch primitive.kind
    {
        case .SPHERE:
            n = #force_inline sphere_normal_from_hit((^Sphere)(primitive), hit_p)
        case .PLANE:
            plane := (^Plane)(primitive)
            n = plane.n
    }
    
    return n
}

@(require_results)
sphere_normal_from_hit :: proc "contextless" (sphere: ^Sphere, hit_p: Vector3) -> Vector3
{
    return normalize(hit_p - sphere.p)
}

normal_from_hit :: proc
{
    primitive_normal_from_hit,
    sphere_normal_from_hit,
}
