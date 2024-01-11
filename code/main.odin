package rt

import "core:fmt"
import "core:math"
import "core:c"
import sdl "vendor:sdl2"

main :: proc()
{
    x := 32
    y := 64
    w := 720
    h := 480

    window     := sdl.CreateWindow  ("odin-rt", c.int(x), c.int(y), c.int(w), c.int(h), sdl.WindowFlags{})
    renderer   := sdl.CreateRenderer(window, -1, sdl.RendererFlags{.ACCELERATED, .PRESENTVSYNC})
    backbuffer := sdl.CreateTexture (renderer, cast(u32)sdl.PixelFormatEnum.RGBA8888, sdl.TextureAccess.STREAMING, c.int(w), c.int(h))

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

    time: f32 = 0.0

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

        pixels_raw : rawptr
        pitch_raw  : c.int
        sdl.LockTexture(backbuffer, nil, &pixels_raw, &pitch_raw)
 
        pitch  := int(pitch_raw / 4)
        pixels := ([^]Color_RGBA)(pixels_raw)[:h*pitch]

        render_target := Render_Target{
            w      = w,
            h      = h,
            pitch  = pitch,
            pixels = pixels,
        }

        camera := Camera{
            origin    = { 0.0, 10.0, -50.0 },
            // direction = { math.sin(25.0*time), 0.0, math.cos(25.0*time) },
            direction = {0.0, 0.0, 1.0 },
            fov       = 85.0,
            aspect    = f32(w) / f32(h),
        }

        view := View{
            scene  = &scene,
            camera = compute_cached_camera(camera),
        }

        moving_sphere.p.y = 25.0 + 7.5*math.sin(5.0*time)

        render_frame(&view, &render_target)

        sdl.UnlockTexture(backbuffer)

        sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
        sdl.RenderSetClipRect(renderer, nil)
        sdl.RenderCopy(renderer, backbuffer, nil, nil)
        sdl.RenderPresent(renderer)

        time += 1.0 / 60.0

        if quit
        {
            break
        }
    }
}
