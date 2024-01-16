package rt

import "core:fmt"
import "core:math"
import "core:c"
import "core:intrinsics"
import "core:time"
import "core:strings"
import sdl "vendor:sdl2"
import mu "vendor:microui"

mu_button_map: []mu.Mouse = {
    sdl.BUTTON_LEFT   = mu.Mouse.LEFT,
    sdl.BUTTON_MIDDLE = mu.Mouse.MIDDLE,
    sdl.BUTTON_RIGHT  = mu.Mouse.RIGHT,
}

mu_key_map: []mu.Key = {
    sdl.Scancode.LSHIFT    = mu.Key.SHIFT,
    sdl.Scancode.RSHIFT    = mu.Key.SHIFT,
    sdl.Scancode.LCTRL     = mu.Key.CTRL,
    sdl.Scancode.RCTRL     = mu.Key.CTRL,
    sdl.Scancode.LALT      = mu.Key.ALT,
    sdl.Scancode.RALT      = mu.Key.ALT,
    sdl.Scancode.RETURN    = mu.Key.RETURN,
    sdl.Scancode.BACKSPACE = mu.Key.BACKSPACE,
}

mu_font_surface : ^sdl.Surface
mu_font         : ^sdl.Texture

mu_rect_from_sdl_rect :: proc(rect: sdl.Rect) -> mu.Rect
{
    return { rect.x, rect.y, rect.w, rect.h }
}

sdl_rect_from_mu_rect :: proc(rect: mu.Rect) -> sdl.Rect
{
    return { rect.x, rect.y, rect.w, rect.h }
}

main :: proc()
{
    window_x := 32
    window_y := 64
    window_w := 1280
    window_h := 720

    sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "1")

    window := sdl.CreateWindow("odin-rt", 
                               c.int(window_x), 
                               c.int(window_y), 
                               c.int(window_w), 
                               c.int(window_h), 
                               sdl.WindowFlags{})

    renderer := sdl.CreateRenderer(window, -1, sdl.RendererFlags{.ACCELERATED, .PRESENTVSYNC})

    preview_w := 720
    preview_h := 405

    backbuffer := sdl.CreateTexture(renderer, 
                                    cast(u32)sdl.PixelFormatEnum.RGBA8888, 
                                    sdl.TextureAccess.STREAMING, 
                                    c.int(preview_w), 
                                    c.int(preview_h))

    //
    // microui
    //

    mu_ctx: mu.Context
    mu.init(&mu_ctx)

    mu_ctx.text_width  = mu.default_atlas_text_width
    mu_ctx.text_height = mu.default_atlas_text_height

    create_mu_font :: proc(renderer: ^sdl.Renderer) -> (surface: ^sdl.Surface, texture: ^sdl.Texture)
    {
        surface = sdl.CreateRGBSurfaceWithFormat(0, mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT, 
                                                 32, cast(u32)sdl.PixelFormatEnum.RGBA8888)
        pixels := ([^]u8)(surface.pixels)
        for i := 0; i < mu.DEFAULT_ATLAS_WIDTH*mu.DEFAULT_ATLAS_HEIGHT; i += 1
        {
            c := mu.default_atlas_alpha[i]
            pixels[4*i + 0] = c
            pixels[4*i + 1] = c
            pixels[4*i + 2] = c
            pixels[4*i + 3] = c
        }
        texture = sdl.CreateTextureFromSurface(renderer, surface)
        return surface, texture
    }

    mu_font_surface, mu_font = create_mu_font(renderer)

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
            translate_button :: proc(button: u8) -> (ok: bool, result: mu.Mouse)
            {
                if int(button) < len(mu_button_map)
                {
                    ok = true
                    result = mu_button_map[button]
                }

                return ok, result
            }

            translate_key :: proc(in_key: sdl.Keycode) -> (ok: bool, result: mu.Key)
            {
                key := i32(in_key) & ~i32(sdl.SCANCODE_MASK)

                if int(key) < len(mu_key_map)
                {
                    ok = true
                    result = mu_key_map[key]
                }

                return ok, result
            }

            #partial switch (event.type)
            {
                case .QUIT:
                    quit = true

                case .MOUSEWHEEL:
                    mu.input_scroll(&mu_ctx, 0, event.wheel.y * -30)

                case .TEXTINPUT:
                    text_as_string := 
                        strings.string_from_null_terminated_ptr(&event.text.text[0], len(event.text.text))

                    mu.input_text(&mu_ctx, text_as_string)

                case .MOUSEMOTION:
                    mu.input_mouse_move(&mu_ctx, event.motion.x, event.motion.y)

                case .MOUSEBUTTONDOWN:
                    ok, button := translate_button(event.button.button)
                    if ok do mu.input_mouse_down(&mu_ctx, event.button.x, event.button.y, button)

                case .MOUSEBUTTONUP:
                    ok, button := translate_button(event.button.button)
                    if ok do mu.input_mouse_up(&mu_ctx, event.button.x, event.button.y, button)

                case .KEYDOWN:
                    ok, key := translate_key(event.key.keysym.sym)
                    if ok do mu.input_key_down(&mu_ctx, key)

                case .KEYUP:
                    ok, key := translate_key(event.key.keysym.sym)
                    if ok do mu.input_key_up(&mu_ctx, key)
            }
        }

        //
        // ui
        //

        mu.begin(&mu_ctx)

        if mu.window(&mu_ctx, "Hello mUI", mu.Rect{ 10, 10, 320, i32(window_h) - 20 })
        {
            mu.label(&mu_ctx, "I'm alive!!!!!!!!!")
        }

        mu.end(&mu_ctx)

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

        origin := Vector3{ 
            50.0*math.cos(0.1*running_time), 
            20.0 + 2.5*math.cos(0.17*running_time), 
            50.0*math.sin(0.1*running_time),
        }
        target    := Vector3{ 0.0, 15.0, 0.0 }
        direction := target - origin

        camera := Camera{
            origin    = origin,
            direction = direction,
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

        //
        // render ui
        //

        render_ui_with_sdl :: proc(ctx: ^mu.Context, renderer: ^sdl.Renderer)
        {
            render_text :: proc(renderer: ^sdl.Renderer, pos: mu.Vec2, color: mu.Color, text: string)
            {
                at := pos

                for ch in text
                {
                    if ch & 0xc0 == 0x80
                    {
                        continue // skip utf-8
                    }

                    r := min(int(ch), 127)

                    src_rect := sdl_rect_from_mu_rect(mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r])
                    dst_rect := sdl.Rect{ at.x, at.y, src_rect.w, src_rect.h }

                    sdl.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
                    sdl.RenderCopy(renderer, mu_font, &src_rect, &dst_rect)

                    at.x += src_rect.w
                }
            }

            render_icon :: proc(renderer: ^sdl.Renderer, rect: mu.Rect, color: mu.Color, icon: mu.Icon)
            {
                src_rect := sdl_rect_from_mu_rect(mu.default_atlas[icon])
                dst_rect := sdl_rect_from_mu_rect(rect)

                sdl.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
                sdl.RenderCopy(renderer, mu_font, &src_rect, &dst_rect)

            }

            command: ^mu.Command
            for mu.next_command(ctx, &command)
            {
                #partial switch v in command.variant
                {
                    case ^mu.Command_Text:
                        render_text(renderer, v.pos, v.color, v.str)

                    case ^mu.Command_Icon:
                        render_icon(renderer, v.rect, v.color, v.id)

                    case ^mu.Command_Rect:
                        sdl.SetRenderDrawColor(renderer, v.color.r, v.color.g, v.color.b, v.color.a)
                        rect := sdl_rect_from_mu_rect(v.rect)
                        sdl.RenderFillRect(renderer, &rect)

                    case ^mu.Command_Clip:
                        rect := sdl_rect_from_mu_rect(v.rect)
                        sdl.RenderSetClipRect(renderer, &rect)
                }
            }
        }
        render_ui_with_sdl(&mu_ctx, renderer)

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

    safely_terminate_render_context(&thread_ctx);
}
