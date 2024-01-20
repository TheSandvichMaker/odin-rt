package rt

// TODO:
// [ ] - grab d3d11 device from SDL and render using d3d11 directly
// [ ] - camera controls
// [ ] - accumulation buffer
// [ ] - tonemapping
// [ ] - basic pathtracing 
// [ ] - image writing
// [ ] - output render mode
// [x] - box intersection
// [ ] - triangle intersection
// [x] - bvh construction
// [ ] - bvh traversal
// [ ] - simple translucency
// [ ] - physically based BRDF
// [ ] - nested objects and material transitions between them
// [ ] - area lights
// [ ] - model loading (cgltf)
// [ ] - scene loading (cgltf)
// [ ] - create scene format
// [ ] - serialize scene format
// [ ] - scene editor controls
// [ ] - scene undo/redo
// [ ] - support multi-scattering in volumetrics
// [ ] - CSG operations
// [ ] - animation support
// [ ] - animation editor
// [ ] - animation rendering

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
    //
    // create window
    //

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

    create_default_atlas_font :: proc(renderer: ^sdl.Renderer) -> (surface: ^sdl.Surface, texture: ^sdl.Texture)
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

    mu_font_surface, mu_font = create_default_atlas_font(renderer)

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

    {
        material := add_material(&scene, { albedo = { 0.2, 0.8, 0.1 }, reflectiveness = 0.5 })
        add_box(&scene, { p = { 0.0, 2.5, 0.0 }, r = { 15.0, 5.0, 15.0 }, material = material })
    }

    {
        material := add_material(&scene, { albedo = { 1.0, 0.0, 0.0 }, reflectiveness = 1.0 })

        spacing := f32(20.0)

        for y := -3; y <= 3; y += 1
        {
            for x := -3; x <= 3; x += 1
            {
                p := Vector3{ f32(x)*spacing, 40.0, f32(y)*spacing }
                add_sphere(&scene, { p = p, r = 7.5, material = material })
            }
        }
    }

    primitives: [dynamic]Primitive_Holder

    for sphere in scene.spheres
    {
        append(&primitives, Primitive_Holder{ sphere = sphere })
    }

    bvh := build_bvh(primitives[:])

    //
    // initialize render context
    //

    rcx: Threaded_Render_Context
    init_render_context(&rcx, { preview_w, preview_h }, max_threads=-1)

    //
    // main loop
    //

    running_time: f32 = 0.0

    now := time.tick_now()
    dt: f32 = 1.0 / 60.0

    view_mode: View_Mode
    show_flags: Show_Flags_Set
    fov := f32(85.0)

    for
    {
        quit := false

        //
        // handle input
        //

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
        // ui logic
        //

        mu.begin(&mu_ctx)

        if mu.window(&mu_ctx, "Hello mUI", mu.Rect{ 10, 10, 320, i32(window_h) - 20 })
        {
            if .ACTIVE in mu.header(&mu_ctx, "View Mode")
            {
                if .SUBMIT in mu.button(&mu_ctx, "Lit")     do view_mode = .LIT
                if .SUBMIT in mu.button(&mu_ctx, "Depth")   do view_mode = .DEPTH
                if .SUBMIT in mu.button(&mu_ctx, "Normals") do view_mode = .NORMALS
            }

            mu.label(&mu_ctx, "fov")
            mu.slider(&mu_ctx, &fov, 45.0, 100.0)
        }

        mu.end(&mu_ctx)

        //
        // display most recent frame
        //

        if frame_available(&rcx)
        {
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
            copy_latest_frame(&rcx, &dst_render_target)

            sdl.UnlockTexture(backbuffer)
        }

        sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
        sdl.RenderSetClipRect(renderer, nil)
        sdl.RenderCopy(renderer, backbuffer, nil, nil)

        //
        // update scene
        //

        moving_sphere.p.y = 25.0 + 7.5*math.sin(running_time)

        //
        // dispatch new frame
        //

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
            fov       = fov,
            aspect    = f32(preview_w) / f32(preview_h),
        }

        view := View{
            scene      = &scene,
            camera     = compute_cached_camera(camera),
            view_mode  = view_mode,
            show_flags = show_flags,
        }

        if can_dispatch_frame(&rcx)
        {
            dispatch_frame(&rcx, view);
        }

        //
        // debug visualization
        //

        Line_Renderer :: struct
        {
            renderer : ^sdl.Renderer,
            camera   : Cached_Camera,
            viewport : Vector2,
        }

        line_renderer := Line_Renderer{
            renderer = renderer,
            camera   = view.camera,
            viewport = Vector2{f32(window_w), f32(window_h)},
        }

        draw_line :: proc(using line_renderer: ^Line_Renderer, color: Vector3, a: Vector3, b: Vector3)
        {
            rgba := rgba8_from_color(color)
            sdl.SetRenderDrawColor(renderer, rgba.r, rgba.g, rgba.b, 255)

            a_projected := project_point(camera, a)
            b_projected := project_point(camera, b)
            
            // very coarse clipping
            if a_projected.z < 0.0 || b_projected.z < 0.0
            {
                return
            }

            a_screen := viewport*(0.5 + 0.5*a_projected.xy)
            b_screen := viewport*(0.5 + 0.5*b_projected.xy)

            sdl.RenderDrawLine(renderer,
                c.int(a_screen.x), c.int(a_screen.y),
                c.int(b_screen.x), c.int(b_screen.y))
        }

        draw_box :: proc(using line_renderer: ^Line_Renderer, color: Vector3, p: Vector3, r: Vector3)
        {
            p000 := p + Vector3{-r.x, -r.y, -r.z}
            p100 := p + Vector3{ r.x, -r.y, -r.z}
            p110 := p + Vector3{ r.x,  r.y, -r.z}
            p010 := p + Vector3{-r.x,  r.y, -r.z}
            p001 := p + Vector3{-r.x, -r.y,  r.z}
            p101 := p + Vector3{ r.x, -r.y,  r.z}
            p111 := p + Vector3{ r.x,  r.y,  r.z}
            p011 := p + Vector3{-r.x,  r.y,  r.z}
            draw_line(line_renderer, color, p000, p100)
            draw_line(line_renderer, color, p000, p010)
            draw_line(line_renderer, color, p110, p100)
            draw_line(line_renderer, color, p110, p010)
            draw_line(line_renderer, color, p001, p101)
            draw_line(line_renderer, color, p001, p011)
            draw_line(line_renderer, color, p111, p101)
            draw_line(line_renderer, color, p111, p011)
            draw_line(line_renderer, color, p000, p001)
            draw_line(line_renderer, color, p100, p101)
            draw_line(line_renderer, color, p110, p111)
            draw_line(line_renderer, color, p010, p011)
        }

        draw_bvh :: proc(using line_renderer: ^Line_Renderer, bvh: ^BVH)
        {
            visitor :: proc(bvh: ^BVH, node: ^BVH_Node, userdata: rawptr)
            {
                line_renderer := (^Line_Renderer)(userdata)
                p, r := rect3_get_position_radius(node.bounds)
                draw_line(line_renderer, Vector3{1, 0, 0}, p, r)
            }

            visit_bvh(bvh, visitor, line_renderer)
        }

        draw_bvh(&line_renderer, &bvh)

        for box in scene.boxes
        {
            material := get_material(&scene, box.material)
            draw_box(&line_renderer, material.albedo, box.p, box.r)
        }

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

        //
        // present
        //

        sdl.RenderPresent(renderer)

        //
        // end of loop guff
        //

        running_time += dt

        dt_hires := time.tick_lap_time(&now)
        dt = math.min(1.0 / 15.0, f32(time.duration_seconds(dt_hires)))

        if quit
        {
            break
        }
    }

    safely_terminate_render_context(&rcx);
}
