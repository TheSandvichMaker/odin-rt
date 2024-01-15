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
        x *= camera.aspect
        o = camera.origin
        film_distance = 1.0 / math.tan(math.to_radians(0.5*camera.fov))
    }

    return cached
}

Ray :: struct
{
    ro: Vector3,
    rd: Vector3,
    t_min: f32,
    t_max: f32,
}

@(require_results)
ray_from_camera :: proc "contextless" (camera: Cached_Camera, ndc: Vector2, t_min, t_max: f32) -> Ray
{
    x := camera.x
    y := camera.y
    z := camera.z
    o := camera.o
    film_distance := camera.film_distance

    d := normalize(ndc.x*x + ndc.y*y - film_distance*z)

    ray := Ray{
        ro    = o,
        rd    = d,
        t_min = t_min,
        t_max = t_max,
    }

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

View :: struct
{
    scene: ^Scene,
    camera: Cached_Camera,
}

Render_Params :: struct
{
    using view: View,
    frame_index : u64,
}

frame_debug_color :: proc(frame_index: u64) -> (result: Vector3)
{
    bits := (frame_index % 6) + 1
    result.x = (bits & 0x1) != 0 ? 1.0 : 0.0
    result.y = (bits & 0x2) != 0 ? 1.0 : 0.0
    result.z = (bits & 0x4) != 0 ? 1.0 : 0.0
    return result
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
    color := shade_ray(scene, ray)

    color = apply_tonemap(color)

    return rgba8_from_color(color)
}

schlick_fresnel :: proc(cos_theta: f32) -> f32
{
    x      := 1.0 - cos_theta
    x2     := x*x
    result := x2*x2*x
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

    primitive, t := intersect_scene(scene, ray)
    if primitive != nil
    {
        color = Vector3{0.0, 0.0, 0.0}

        p := ro + t*rd
        n: Vector3 = normal_from_hit(primitive, p)

        n_dot_l := math.max(0.0, dot(sun.d, n))

        material := get_material(scene, primitive.material)

        if n_dot_l > 0.0
        {
            shadow_ray := Ray{
                ro    = p + 0.0001*n,
                rd    = sun.d,
                t_min = t_min,
                t_max = t_max,
            }

            in_shadow := intersect_scene_shadow(scene, shadow_ray)

            if !in_shadow
            {
                color = material.albedo*sun.color*n_dot_l
            }
        }

        if material.reflectiveness > 0.0
        {
            next_ray := Ray{
                ro    = p + 0.0001*n,
                rd    = reflect(rd, n),
                t_min = t_min,
                t_max = t_max,
            }

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
