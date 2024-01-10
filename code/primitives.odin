package rt

import "core:math"

Material :: struct
{
    albedo: Vector3,
    reflectiveness: f32,
}

Material_Index :: distinct u32

Sphere :: struct
{
    p        : Vector3,
    r        : f32,
    material : Material_Index,
}

intersect_sphere :: proc(sphere: ^Sphere, ray: Ray) -> (hit: bool, t: f32)
{
    using ray

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

normal_from_hit :: proc(sphere: ^Sphere, hit_p: Vector3) -> Vector3
{
    return normalize(hit_p - sphere.p)
}
