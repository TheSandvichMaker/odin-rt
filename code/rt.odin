package rt

import "core:intrinsics"
import "core:math"
import "core:math/linalg"

Camera_Controller :: struct
{
    origin : Vector3,
    pitch  : f32,
    yaw    : f32,
    roll   : f32,
}

@(require_results)
camera_from_controller :: proc(controller: Camera_Controller, fov: f32, aspect: f32) -> Camera
{
    quat      := linalg.quaternion_from_pitch_yaw_roll(controller.pitch, controller.yaw, controller.roll)
    direction := linalg.mul(quat, Vector3{0.0, 0.0, -1.0})
    
    result := Camera{
        origin    = controller.origin,
        direction = direction,
        fov       = fov,
        aspect    = aspect,
    }

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

delete_render_target :: proc(target: ^Render_Target)
{
    delete(target.pixels)

    target.w      = 0
    target.h      = 0
    target.pitch  = 0
    target.pixels = nil
}

copy_render_target :: proc(dst: ^Render_Target, src: ^Render_Target) -> (copied: bool)
{
    dst_w      := dst.w
    dst_h      := dst.h
    dst_pitch  := dst.pitch
    dst_pixels := dst.pixels

    src_w      := src.w
    src_h      := src.h
    src_pitch  := src.pitch
    src_pixels := src.pixels

    if dst_w >= src_w &&
       dst_h >= src_h
    {
        w := src_w
        h := src_h

        for y := 0; y < h; y += 1
        {
            for x := 0; x < w; x += 1
            {
                #no_bounds_check dst_pixels[y*dst_pitch + x] = src_pixels[y*src_pitch + x]
            }
        }

        copied = true
    }

    return copied
}

Accumulation_Buffer :: struct
{
    accumulated_frame_count : u64,
    w      : int,
    h      : int,
    pitch  : int,
    pixels : []Vector4,
}

allocate_accumulation_buffer :: proc(resolution: [2]int) -> Accumulation_Buffer
{
    result := Accumulation_Buffer{
        w      = resolution.x,
        h      = resolution.y,
        pitch  = resolution.x,
        pixels = make([]Vector4, resolution.x*resolution.y),
    }
    return result
}

View_Mode :: enum
{
    Blank,
    Lit,
    Depth,
    Normals,
}

Show_Flags :: enum
{
    Draw_BVH,
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

    rcx                 : ^Threaded_Render_Context,
    frame_index         : u64,
    render_target       : ^Render_Target,
    accumulation_buffer : ^Accumulation_Buffer,
    accum_needs_clear   : bool,
    spp                 : int,
    rand                : Xorshift32_State,
}

render_tile :: proc(params: Render_Params, x0_, x1_, y0_, y1_: int)
{
    render_target       := params.render_target
    accumulation_buffer := params.accumulation_buffer
    accum_needs_clear   := params.accum_needs_clear
    spp                 := u64(params.spp)
    rand                := params.rand

    w      := render_target.w
    h      := render_target.h
    pitch  := render_target.pitch
    pixels := render_target.pixels

    base_sample_index: u64 = 0

    if accumulation_buffer != nil
    {
        base_sample_index = accumulation_buffer.accumulated_frame_count
    }

    pixsize := 1.0 / Vector2{f32(w), f32(h)}

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

            pixel_hdr: Vector4

            for sample_index: u64 = 0; sample_index < spp; sample_index += 1
            {
                abs_sample_index := base_sample_index + sample_index

                noise: Vector3
                if !accum_needs_clear
                {
                    noise = random_bilateral_v3(&rand)
                }

                jitter     := pixsize*noise.xy
                ndc_jitter := ndc + jitter

                pixel_hdr += render_pixel(params, ndc_jitter)
            }

            if accumulation_buffer != nil
            {
                accum_pitch  := accumulation_buffer.pitch
                accum_pixels := &accumulation_buffer.pixels

                if !accum_needs_clear
                {
                    #no_bounds_check accum := accum_pixels[y*accum_pitch + x]
                    pixel_hdr += accum
                }

                #no_bounds_check accum_pixels[y*accum_pitch + x] = pixel_hdr
            }

            pixel_sdr := tonemap_pixel(params, pixel_hdr)

            #no_bounds_check pixels[y*pitch + x] = pixel_sdr
        }
    }
}

@(require_results)
render_pixel :: proc(using params: Render_Params, ndc: Vector2) -> Vector4
{
    ray := ray_from_camera(camera, ndc, 0.001, math.F32_MAX)

    color: Vector3

    switch view_mode
    {
    case .Blank:
        /* ... */
    case .Lit:
        color = shade_ray(scene, ray)
    case .Depth:
        color = show_depth(scene, ray)
    case .Normals:
        color = show_normals(scene, ray)
    }

    return Vector4{color.x, color.y, color.z, 1.0}
}

@(require_results)
tonemap_pixel :: proc(using params: Render_Params, color: Vector4) -> Color_RGBA
{
    color := color
    color.xyz /= color.w

    color.xyz = apply_tonemap(color.xyz)
    return rgba8_from_color(color.xyz)
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
            shadow_ray := make_ray(p + 0.0001*n, sun.d, t_min, t_max)
            in_shadow := intersect_scene_shadow(scene, shadow_ray)

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
