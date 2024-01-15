package rt

import "core:fmt"
import "core:math"
import "core:c"
import "core:intrinsics"
import "core:time"
import sdl "vendor:sdl2"

main :: proc()
{
    window_x := 32
    window_y := 64
    window_w := 720
    window_h := 480

    sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "1")

    window := sdl.CreateWindow("odin-rt", 
                               c.int(window_x), 
                               c.int(window_y), 
                               c.int(window_w), 
                               c.int(window_h), 
                               sdl.WindowFlags{})

    renderer := sdl.CreateRenderer(window, -1, sdl.RendererFlags{.ACCELERATED, .PRESENTVSYNC})

    preview_w := 480
    preview_h := 320

    backbuffer := sdl.CreateTexture(renderer, 
                                    cast(u32)sdl.PixelFormatEnum.RGBA8888, 
                                    sdl.TextureAccess.STREAMING, 
                                    c.int(preview_w), 
                                    c.int(preview_h))

    //
    // scene setup
    //

    scene: Scene

    sun := &scene.sun
    sun.d     = normalize(Vector3{0.2, 0.8, 0.3})
    sun.color = Vector3{1.0, 1.0, 1.0}

    {
        material := add_material(&scene, { albedo = { 1.0, 0.5, 0.2 }, reflectiveness = 0.25 })
        add_plane(&scene, { p = { 0.0, 0.0, 0.0 }, n = { 0.0, 1.0, 0.0 }, material = material })
    }

    moving_sphere: ^Sphere
    {
        material := add_material(&scene, { albedo = { 0.0, 0.5, 1.0 }, reflectiveness = 1.0 })
        moving_sphere = add_sphere(&scene, { p = { 0.0, 15.0, 0.0 }, r = 15.0, material = material })
    }

    //
    //
    //

    running_time: f32 = 0.0

    thread_ctx: Threaded_Render_Context
    init_render_context(&thread_ctx, { preview_w, preview_h }, max_threads=-1)

    now := time.tick_now()
    dt: f32 = 1.0 / 60.0

    for
    {
        quit := false

        event: sdl.Event
        for sdl.PollEvent(&event)
        {
            #partial switch (event.type)
            {
                case .QUIT:
                    quit = true
            }
        }

        // -- 

        pixels_raw : rawptr
        pitch_raw  : c.int
        sdl.LockTexture(backbuffer, nil, &pixels_raw, &pitch_raw)

        dst_pitch  := int(pitch_raw / 4)
        dst_pixels := ([^]Color_RGBA)(pixels_raw)[:preview_h*dst_pitch]
 
        dst_render_target := Render_Target{
            w      = preview_w,
            h      = preview_h,
            pitch  = dst_pitch,
            pixels = dst_pixels,
        }
        maybe_copy_latest_frame(&thread_ctx, &dst_render_target)

        sdl.UnlockTexture(backbuffer)

        // --

        camera := Camera{
            origin    = { 0.0, 10.0, -50.0 },
            direction = { 0.0, 0.0, 1.0 },
            fov       = 85.0,
            aspect    = f32(preview_w) / f32(preview_h),
        }

        view := View{
            scene  = &scene,
            camera = compute_cached_camera(camera),
        }

        moving_sphere.p.y = 25.0 + 7.5*math.sin(running_time)

        maybe_dispatch_frame(&thread_ctx, view);

        // --

        sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
        sdl.RenderSetClipRect(renderer, nil)
        sdl.RenderCopy(renderer, backbuffer, nil, nil)
        sdl.RenderPresent(renderer)

        // -- 

        running_time += dt

        dt_hires := time.tick_lap_time(&now)
        dt = math.min(1.0 / 15.0, f32(time.duration_seconds(dt_hires)))

        if quit
        {
            break
        }
    }
}
