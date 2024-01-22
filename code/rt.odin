package rt

import "core:math"
import "core:math/linalg"

Camera :: struct
{
    origin    : Vector3,
    direction : Vector3,
    fov       : f32,
    aspect    : f32, // width over height
}

Cached_Camera  :: struct
{
    x: Vector3,
    y: Vector3,
    z: Vector3,
    o: Vector3,
    film_distance: f32,
    aspect: f32,
}

@(require_results)
compute_cached_camera :: proc "contextless" (camera: Camera) -> Cached_Camera 
{
    WORLD_UP :: Vector3{ 0, 1, 0 }

    cached: Cached_Camera
    {
        using cached

        x = normalize(cross(WORLD_UP, camera.direction))
        y = normalize(cross(camera.direction, x))
        z = normalize(cross(y, x))
        o = camera.origin
        aspect = camera.aspect
        film_distance = 1.0 / math.tan(math.to_radians(0.5*camera.fov))
    }

    return cached
}

@(require_results)
project_point :: proc "contextless" (camera: Cached_Camera, p: Vector3) -> Vector3
{
    camera_rel_p := p - camera.o

    camera_p := Vector3{
         dot(camera.x, camera_rel_p), 
        -dot(camera.y, camera_rel_p),
        -dot(camera.z, camera_rel_p),
    }

    projected_p := camera_p
    projected_p.xy *= camera.film_distance / camera_p.z
    projected_p.x  /= camera.aspect
    return projected_p
}

Ray :: struct
{
    ro: Vector3,
    rd: Vector3,
    rd_inv: Vector3,
    t_min: f32,
    t_max: f32,
}

@(require_results)
make_ray :: proc "contextless" (ro: Vector3, rd: Vector3, t_min: f32 = 0.001, t_max: f32 = math.F32_MAX) -> Ray
{
    ray := Ray{
        ro     = ro,
        rd     = rd,
        rd_inv = 1.0 / rd,
        t_min  = t_min,
        t_max  = t_max,
    }
    return ray
}

@(require_results)
ray_from_camera_uv :: proc "contextless" (camera: Cached_Camera, uv: Vector2, t_min: f32 = 0.001, t_max: f32 = math.F32_MAX) -> Ray
{
    ndc := 2.0*uv - 1.0
    ray := ray_from_camera(camera, ndc, t_min, t_max)
    return ray
}

@(require_results)
ray_from_camera :: proc "contextless" (camera: Cached_Camera, ndc: Vector2, t_min, t_max: f32) -> Ray
{
    x := camera.x
    y := camera.y
    z := camera.z
    film_distance := camera.film_distance

    ro := camera.o
    rd := normalize(ndc.x*x*camera.aspect + ndc.y*y - film_distance*z)

    ray := make_ray(ro, rd, t_min, t_max)
    return ray
}

Render_Target :: struct
{
    w      : int,
    h      : int,
    pitch  : int,
    pixels : []Color_RGBA,
}

allocate_render_target :: proc(resolution: [2]int) -> Render_Target
{
    using result: Render_Target
    w      = resolution.x
    h      = resolution.y
    pitch  = w
    pixels = make([]Color_RGBA, w*h)
    return result
}

Accumulation_Buffer :: struct
{
    accumulated_frame_count : int,
    w      : int,
    h      : int,
    pitch  : int,
    pixels : []Vector3,
}

View_Mode :: enum
{
    BLANK,
    LIT,
    DEPTH,
    NORMALS,
}

Show_Flags :: enum
{
    DRAW_BVH,
}

Show_Flags_Set :: bit_set[Show_Flags]

View :: struct
{
    scene      : ^Scene,
    camera     : Cached_Camera,
    view_mode  : View_Mode,
    show_flags : Show_Flags_Set,
}

Render_Params :: struct
{
    using view: View,
    frame_index : u64,
}

render_tile :: proc(params: Render_Params, render_target: ^Render_Target, x0_, x1_, y0_, y1_: int)
{
    w      := render_target.w
    h      := render_target.h
    pitch  := render_target.pitch
    pixels := render_target.pixels

    x0 := math.clamp(x0_, 0, w)
    x1 := math.clamp(x1_, 0, w)
    y0 := math.clamp(y0_, 0, h)
    y1 := math.clamp(y1_, 0, h)

    for y := y0; y < y1; y += 1
    {
        ndc_y := 1.0 - 2.0*(f32(y) / f32(h))

        for x := x0; x < x1; x += 1
        {
            ndc_x := 2.0*(f32(x) / f32(w)) - 1.0

            ndc := Vector2{ndc_x, ndc_y}
            pixel := render_pixel(params, ndc)

            pixels[y*pitch + x] = pixel
        }
    }
}

@(require_results)
render_pixel :: proc(using params: Render_Params, ndc: Vector2) -> Color_RGBA
{
    ray   := ray_from_camera(camera, ndc, 0.001, math.F32_MAX)

    color: Vector3

    switch view_mode
    {
    case .BLANK:
        /* ... */
    case .LIT:
        color = shade_ray(scene, ray)
    case .DEPTH:
        color = show_depth(scene, ray)
    case .NORMALS:
        color = show_normals(scene, ray)
    }

    color = apply_tonemap(color)

    return rgba8_from_color(color)
}

show_depth :: proc(scene: ^Scene, using ray: Ray) -> Vector3
{
    result := Vector3{0, 0, 0}

    primitive, t := intersect_scene(scene, ray)
    if primitive != nil
    {
        result = Vector3{t, t, t} / 1000.0
    }

    return result
}

show_normals :: proc(scene: ^Scene, using ray: Ray) -> Vector3
{
    result := Vector3{0, 0, 0}

    primitive, t := intersect_scene(scene, ray)
    if primitive != nil
    {
        p := ro + t*rd
        n: Vector3 = normal_from_hit(primitive, p)
        result = 0.5 + 0.5*n
    }

    return result
}

shade_ray :: proc(scene: ^Scene, using ray: Ray, recursion := 4) -> Vector3
{
    if (recursion == 0)
    {
        return Vector3{0.0, 0.0, 0.0}
    }

    color := Vector3{0.3, 0.5, 0.9}

    sun := scene.sun

    // primitive, t := intersect_scene(scene, ray)
    primitive, t := intersect_scene_accelerated(scene, ray)
    if primitive != nil
    {
        color = Vector3{0.0, 0.0, 0.0}

        p := ro + t*rd
        n: Vector3 = normal_from_hit(primitive, p)

        n_dot_l := math.max(0.0, dot(sun.d, n))

        material := get_material(scene, primitive.material)

        if n_dot_l > 0.0
        {
            shadow_ray := make_ray(p + 0.0001*n, sun.d, t_min, t_max)
            // in_shadow := intersect_scene_shadow(scene, shadow_ray)
            in_shadow := intersect_scene_shadow_accelerated(scene, shadow_ray)

            if !in_shadow
            {
                color = material.albedo*sun.color*n_dot_l
            }
        }

        if material.reflectiveness > 0.0
        {
            next_ray := make_ray(p + 0.0001*n, reflect(rd, n), t_min, t_max)

            cos_theta := -dot(rd, n)
            fresnel   := schlick_fresnel(cos_theta)
            color += material.reflectiveness*fresnel*shade_ray(scene, next_ray, recursion - 1)
        }
    }

    return color
}

@(require_results)
apply_tonemap :: proc(color: Vector3) -> Vector3
{
    result := Vector3{
        1.0 - math.exp(-color.x),
        1.0 - math.exp(-color.y),
        1.0 - math.exp(-color.z),
    }

    return result
}
