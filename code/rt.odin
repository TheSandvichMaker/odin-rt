package rt

import "core:math"
import "core:math/linalg"

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

dot       :: linalg.dot
cross     :: linalg.cross
normalize :: linalg.normalize
reflect   :: linalg.reflect

Color_RGBA :: struct
{
    a: u8,
    b: u8,
    g: u8,
    r: u8,
}

color_rgb :: proc(r, g, b: u8) -> Color_RGBA
{
    return { 255, b, g, r }
}

color_rgba :: proc(r, g, b, a: u8) -> Color_RGBA
{
    return { a, b, g, r }
}

srgb_from_linear :: proc(lin: Vector3) -> Vector3
{
    return Vector3{
        math.sqrt(lin.x),
        math.sqrt(lin.y),
        math.sqrt(lin.z),
    }
}

rgba8_from_color :: proc(in_color: Vector3, to_srgb := true) -> Color_RGBA
{
    result: Color_RGBA 

    color := to_srgb ? srgb_from_linear(in_color) : in_color;

    using result
    r = u8(255.0*color.x)
    g = u8(255.0*color.y)
    b = u8(255.0*color.z)
    a = 255

    return result
}

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

Ray :: struct
{
    ro: Vector3,
    rd: Vector3,
    t_min: f32,
    t_max: f32,
}

Render_Target :: struct
{
    w      : int,
    h      : int,
    pitch  : int,
    pixels : []Color_RGBA,
}

View :: struct
{
    scene: ^Scene,
    camera: Cached_Camera,
}

render_frame :: proc(view: ^View, render_target: ^Render_Target)
{
    scene := view.scene

    w      := render_target.w
    h      := render_target.h
    pitch  := render_target.pitch
    pixels := render_target.pixels

    for y := 0; y < h; y += 1
    {
        ndc_y := 1.0 - 2.0*(f32(y) / f32(h))

        for x := 0; x < w; x += 1
        {
            ndc_x := 2.0*(f32(x) / f32(w)) - 1.0

            ndc := Vector2{ ndc_x, ndc_y }

            pixel := render_pixel(view, ndc)

            #no_bounds_check {
                pixels[y*pitch + x] = pixel
            }
        }
    }
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
    color := Vector3{0.3, 0.5, 0.9}

    if (recursion == 0)
    {
        return color
    }

    sun := scene.sun

    sphere, t := intersect_scene(scene, ray)
    if sphere != nil
    {
        color = Vector3{0.0, 0.0, 0.0}

        p := ro + t*rd
        n := normal_from_hit(sphere, p)

        n_dot_l := math.max(0.0, dot(sun.d, n))

        material := get_material(scene, sphere.material)

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
render_pixel :: proc(view: ^View, ndc: Vector2) -> Color_RGBA
{
    camera := view.camera
    scene  := view.scene

    ray   := ray_from_camera(camera, ndc, 0.001, math.F32_MAX)
    color := shade_ray(scene, ray)

    return rgba8_from_color(color)
}
