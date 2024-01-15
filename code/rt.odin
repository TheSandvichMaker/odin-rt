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

Render_Params :: struct
{
    camera      : Cached_Camera,
    scene       : ^Scene,
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

@(require_results)
render_pixel :: proc(using params: Render_Params, ndc: Vector2) -> Color_RGBA
{
    ray   := ray_from_camera(camera, ndc, 0.001, math.F32_MAX)
    color := shade_ray(scene, ray)

    color = apply_tonemap(color)

    return rgba8_from_color(color)
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
