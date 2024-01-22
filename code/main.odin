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
import "core:slice"
import "core:runtime"
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

mu_color_from_linear_srgb :: proc(srgb: Vector3) -> mu.Color
{
    rgba := rgba8_from_color(srgb)
    result := mu.Color{
        r = rgba.r,
        g = rgba.g,
        b = rgba.b,
        a = rgba.a,
    }
    return result
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

    /*
    moving_sphere: ^Sphere
    {
        material := add_material(&scene, { albedo = { 0.0, 0.5, 1.0 }, reflectiveness = 1.0 })
        moving_sphere = add_sphere(&scene, { p = { 0.0, 15.0, 0.0 }, r = 15.0, material = material })
    }

    {
        material := add_material(&scene, { albedo = { 0.2, 0.8, 0.1 }, reflectiveness = 0.5 })
        add_box(&scene, { p = { 0.0, 2.5, 0.0 }, r = { 15.0, 5.0, 15.0 }, material = material })
    }
    */

    {
        material := add_material(&scene, { albedo = { 1.0, 0.0, 0.0 }, reflectiveness = 0.0 })

        spacing := f32(20.0)

        for y := -3; y <= 3; y += 1
        {
            for x := -3; x <= 3; x += 1
            {
                p := Vector3{ f32(x)*spacing, 10.0, f32(y)*spacing }
                add_box(&scene, { p = p, r = 7.5, material = material })
            }
        }
    }

    primitives: [dynamic]Primitive_Holder

    for box in scene.boxes
    {
        append(&primitives, Primitive_Holder{ box = box })
    }

    // TODO: figure it out!
    scene.bvh = build_bvh(primitives[:])
    scene.primitives = primitives

    //
    // initialize render context
    //

    rcx: Threaded_Render_Context
    init_render_context(&rcx, { preview_w, preview_h }, max_threads=-1)

    //
    // main loop
    //

    running_time: f64 = 0.0

    now := time.tick_now()
    dt: f32 = 1.0 / 60.0

    view_mode: View_Mode = .LIT
    show_flags: Show_Flags_Set
    fov := f32(85.0)

    bvh_max_depth := find_bvh_max_depth(&scene.bvh)

    Draw_BVH_Args :: struct
    {
        show_depth: int `ui_min: -1, ui_max: 10`,
    }

    draw_bvh_args: Draw_BVH_Args = {
        show_depth = -1,
    }

    mouse_p: [2]int
    lmb_down     : bool
    lmb_pressed  : bool
    lmb_released : bool

    pause_animations: bool
    last_camera: Cached_Camera

    for
    {
        quit := false

        //
        // handle input
        //

        lmb_pressed  = false
        lmb_released = false

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
                    mouse_p[0] = int(event.motion.x)
                    mouse_p[1] = int(event.motion.y)

                case .MOUSEBUTTONDOWN:
                    ok, button := translate_button(event.button.button)
                    if ok do mu.input_mouse_down(&mu_ctx, event.button.x, event.button.y, button)
                    if button == .LEFT
                    {
                        lmb_pressed = true
                        lmb_down    = true
                    }

                case .MOUSEBUTTONUP:
                    ok, button := translate_button(event.button.button)
                    if ok do mu.input_mouse_up(&mu_ctx, event.button.x, event.button.y, button)
                    if button == .LEFT
                    {
                        lmb_released = true
                        lmb_down     = false
                    }

                case .KEYDOWN:
                    ok, key := translate_key(event.key.keysym.sym)
                    if ok do mu.input_key_down(&mu_ctx, key)

                case .KEYUP:
                    ok, key := translate_key(event.key.keysym.sym)
                    if ok do mu.input_key_up(&mu_ctx, key)
            }
        }

        mu_has_mouse := mu_ctx.hover_id != 0

        debug_ray_primitive: ^Primitive
        debug_ray_t: f32
        debug_ray_info: Ray_Debug_Info

        if !mu_has_mouse && lmb_down
        {
            uv := Vector2{f32(mouse_p[0]) / f32(window_w), 1.0 - f32(mouse_p[1]) / f32(window_h)}
            ray := ray_from_camera_uv(last_camera, uv)
            prev_allocator := context.allocator
            context.allocator = context.temp_allocator
            debug_ray_primitive, debug_ray_t = intersect_scene_accelerated_impl(&scene, ray, EARLY_OUT=false, WRITE_DEBUG_INFO=true, debug=&debug_ray_info)
            context.allocator = prev_allocator
        }

        //
        // ui logic
        //

        mu.begin(&mu_ctx)

        if mu.window(&mu_ctx, "Hello mUI", mu.Rect{ 10, 10, 320, i32(window_h) - 20 })
        {
            // mu_struct(&mu_ctx, &draw_bvh_args)

            mu_flags :: proc(mu_ctx: ^mu.Context, flags: ^bit_set[$T])
            {
                type_info := type_info_of(T)
                if named_info, ok := type_info.variant.(runtime.Type_Info_Named); ok
                {
                    if enum_info, ok := named_info.base.variant.(runtime.Type_Info_Enum); ok
                    {
                        for _, i in enum_info.names
                        {
                            name  := enum_info.names[i]
                            value := enum_info.values[i]
                            state := T(value) in flags
                            mu.checkbox(mu_ctx, name, &state)
                            if state 
                            {
                                incl(flags, T(value))
                            }
                            else
                            {
                                excl(flags, T(value))
                            }
                        }
                    }
                }
            }

            mu_enum_selection :: proc(mu_ctx: ^mu.Context, $T: typeid) -> (changed: bool, result: T)
            {
                type_info := type_info_of(T)
                if named_info, ok := type_info.variant.(runtime.Type_Info_Named); ok
                {
                    if enum_info, ok := named_info.base.variant.(runtime.Type_Info_Enum); ok
                    {
                        for _, i in enum_info.names
                        {
                            name  := enum_info.names[i]
                            value := enum_info.values[i]
                            if .SUBMIT in mu.button(mu_ctx, name)
                            {
                                return true, T(value)
                            }
                        }
                    }
                }

                return false, T{}
            }

            mu.checkbox(&mu_ctx, "Pause Animations", &pause_animations)

            if .ACTIVE in mu.header(&mu_ctx, "View Mode")
            {
                if changed, value := mu_enum_selection(&mu_ctx, View_Mode); changed
                {
                    view_mode = value
                }
            }

            if .ACTIVE in mu.header(&mu_ctx, "Show Flags")
            {
                mu_flags(&mu_ctx, &show_flags)
            }

            if .DRAW_BVH in show_flags
            {
                if .ACTIVE in mu.header(&mu_ctx, "Draw BVH")
                {
                    mu.label(&mu_ctx, "Show Depth")
                    mu_slider_int(&mu_ctx, &draw_bvh_args.show_depth, -1, bvh_max_depth - 1)
                }
            }

            mu.label(&mu_ctx, "fov")
            mu.slider(&mu_ctx, &fov, 45.0, 100.0)

            if len(debug_ray_info.nodes_tried) != 0
            {
                mu.text(&mu_ctx, fmt.tprint("Debug Ray Primitive: %v", debug_ray_primitive))
                for node_index in debug_ray_info.nodes_tried
                {
                    type := "missed"

                    not_present := false
                    if debug_ray_info.closest_hit_node == node_index
                    {
                        type = "leaf"
                    }
                    else if slice.contains(debug_ray_info.nodes_hit[:], node_index)
                    {
                        type = "hit"
                    }
                    else if slice.contains(debug_ray_info.nodes_missed[:], node_index)
                    {
                        type = "missed"
                    }
                    else
                    {
                        not_present = true
                    }

                    if !not_present
                    {
                        node := &scene.bvh.nodes[node_index]
                        mu.text(&mu_ctx, fmt.tprint("Node (%v): %v", type, node))
                    }
                }
            }
            else if lmb_down
            {
                mu.text(&mu_ctx, "Debug Ray Primitive: None")
            }
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

        // moving_sphere.p.y = 25.0 + 7.5*math.sin(running_time)

        //
        // dispatch new frame
        //

        origin := Vector3{ 
            f32(50.0*math.cos(0.1*running_time)),
            f32(60.0 + 20.0*math.cos(0.17*running_time)), 
            f32(50.0*math.sin(0.1*running_time)),
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

        last_camera = view.camera

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

        if .DRAW_BVH in show_flags || len(debug_ray_info.nodes_tried) > 0
        {
            if len(debug_ray_info.nodes_tried) > 0
            {
                for node_index in debug_ray_info.nodes_tried
                {
                    missed_color :: Vector3{1, 0, 0}
                    hit_color    :: Vector3{0, 1, 0}
                    leaf_color   :: Vector3{0, 0, 1}

                    not_present := false
                    color := Vector3{0, 0, 0}

                    if debug_ray_info.closest_hit_node == node_index
                    {
                        color = leaf_color
                    }
                    else if slice.contains(debug_ray_info.nodes_hit[:], node_index)
                    {
                        color = hit_color
                    }
                    else if slice.contains(debug_ray_info.nodes_missed[:], node_index)
                    {
                        color = missed_color
                    }
                    else
                    {
                        not_present = true
                    }

                    if !not_present
                    {
                        node := &scene.bvh.nodes[node_index]
                        p, r := rect3_get_position_radius(node.bounds)
                        draw_box(&line_renderer, color, p, r)
                    }
                }
            }
            else
            {
                My_Args :: struct
                {
                    line_renderer  : ^Line_Renderer,
                    draw_args      : ^Draw_BVH_Args,
                    debug_ray_info : ^Ray_Debug_Info,
                }

                my_args := My_Args{ &line_renderer, &draw_bvh_args, &debug_ray_info }

                visit_bvh(&scene.bvh, &my_args, proc(args: BVH_Visitor_Args)
                {
                    using my_args := (^My_Args)(args.userdata)

                    {
                        max_depth := 10
                        if draw_args.show_depth == -1 || draw_args.show_depth == args.depth
                        {
                            color := debug_color(args.depth)

                            p, r := rect3_get_position_radius(args.node.bounds)
                            draw_box(line_renderer, color, p, r)
                        }
                    }
                })
            }
        }

        // for box in scene.boxes
        // {
        //     material := get_material(&scene, box.material)
        //     draw_box(&line_renderer, material.albedo, box.p, box.r)
        // }

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

        if !pause_animations
        {
            running_time += f64(dt)
        }

        dt_hires := time.tick_lap_time(&now)
        dt = math.min(1.0 / 15.0, f32(time.duration_seconds(dt_hires)))

        free_all(context.temp_allocator)

        if quit
        {
            break
        }
    }

    safely_terminate_render_context(&rcx);
}
