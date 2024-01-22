package rt

import "core:math"
import "core:simd"

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
    BOX,
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

Box :: struct
{
    using base: Primitive,
    r: Vector3,
}

Primitive_Holder :: struct #raw_union
{
    primitive : Primitive,
    sphere    : Sphere,
    plane     : Plane,
    box       : Box,
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
intersect_box_simple :: #force_no_inline proc "contextless" (ray: Ray, box_min: Vector3, box_max: Vector3) -> (hit: bool, t: f32)
{
    t1 := ray.rd_inv*(box_min - ray.ro)
    t2 := ray.rd_inv*(box_max - ray.ro)

    tn := max3(component_min(t1, t2))
    tf := min3(component_max(t1, t2))

    t   = tn >= 0.0 ? tn : tf
    hit = tf >= tn && t >= ray.t_min && t < ray.t_max

    return hit, t
}

@(require_results)
intersect_box :: #force_no_inline proc "contextless" (box: ^Box, r: Ray) -> (hit: bool, t: f32)
{
    // to review: https://iquilezles.org/articles/boxfunctions/

    IQ :: false
    when IQ
    {
        m  := r.rd_inv
        n  := m*(r.ro - box.p)
        k  := component_abs(m)*box.r
        t1 := -n - k
        t2 := -n + k
        tn := max3(t1)
        tf := min3(t2)

        t   = tn
        hit = t >= r.t_min && tf >= tn
    }
    else
    {
        SIMD :: true
        when SIMD
        {
            // this is silly. don't do SIMD like this!
            box_p := #force_inline f32x4_from(box.p.x, box.p.y, box.p.z, math.QNAN_F32)
            box_r := #force_inline f32x4_from(box.r)

            box_min := box_p - box_r
            box_max := box_p + box_r

            ro     := #force_inline f32x4_from(r.ro)
            rd_inv := #force_inline f32x4_from(r.rd_inv)

            t1 := rd_inv*(box_min - ro)
            t2 := rd_inv*(box_max - ro)

            tn := simd.reduce_max(simd.min(t1, t2))
            tf := simd.reduce_min(simd.max(t1, t2))
            
            t   = tn
            hit = t >= r.t_min && tf >= tn
        }
        else
        {
            box_min := box.p - box.r
            box_max := box.p + box.r

            t1 := r.rd_inv*(box_min - r.ro)
            t2 := r.rd_inv*(box_max - r.ro)

            tn := max3(component_min(t1, t2))
            tf := min3(component_max(t1, t2))

            t   = tn
            hit = t >= r.t_min && tf >= tn
        }
    }

    return hit, t
}

@(require_results)
intersect_primitive :: proc "contextless" (primitive: ^Primitive, ray: Ray) -> (hit: bool, t: f32)
{
    switch primitive.kind
    {
        case .SPHERE:
            hit, t = intersect_sphere((^Sphere)(primitive), ray)
        case .PLANE:
            hit, t = intersect_plane((^Plane)(primitive), ray)
        case .BOX:
            hit, t = intersect_box((^Box)(primitive), ray)
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
            n = sphere_normal_from_hit((^Sphere)(primitive), hit_p)
        case .PLANE:
            n = (^Plane)(primitive).n
        case .BOX:
            n = box_normal_from_hit((^Box)(primitive), hit_p)
    }
    
    return n
}

@(require_results)
sphere_normal_from_hit :: proc "contextless" (sphere: ^Sphere, hit_p: Vector3) -> Vector3
{
    return normalize(hit_p - sphere.p)
}

@(require_results)
box_normal_from_hit :: proc "contextless" (box: ^Box, hit_p: Vector3) -> (n: Vector3)
{
    rel_p := hit_p - box.p
    norm  := rel_p / box.r

    SLOW_BUT_ACCURATE :: false

    when SLOW_BUT_ACCURATE
    {
        // TODO: Write (more) optimized version of this

        largest_i := 0
        largest   := abs(norm.x)

        for i := 1; i < 3; i += 1
        {
            x_abs := abs(norm[i])

            if x_abs > largest
            {
                largest_i = i
                largest   = x_abs
            }
        }

        n[largest_i] = math.sign(norm[largest_i])
    }
    else
    {
        norm_i := vector3_cast(i32, 1.000001*norm)
        n = vector3_cast(f32, norm_i)
    }

    return n
}

normal_from_hit :: proc
{
    primitive_normal_from_hit,
    sphere_normal_from_hit,
    box_normal_from_hit,
}
