package rt

// TODO:
// [ ] - grab d3d11 device from SDL and render using d3d11 directly
// [ ] - camera controls
// [x] - accumulation buffer
// [x] - tonemapping
// [ ] - basic pathtracing 
// [x] - image writing
// [x] - output render mode
// [x] - box intersection
// [ ] - triangle intersection
// [x] - bvh construction
// [x] - bvh traversal/intersection
// [ ] - simple translucency
// [ ] - physically based BRDF
// [ ] - nested objects and material transitions between them
// [ ] - area lights
// [ ] - model loading (cgltf)
// [ ] - scene loading (cgltf)
// [ ] - create scene format
// [ ] - serialize scene format
// [ ] - replace microui
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
import "core:os"
import path "core:path/filepath"
import sm   "core:container/small_array"
import sdl  "vendor:sdl2"
import mu   "vendor:microui"
import stbi "vendor:stb/image"

Picture_State :: enum
{
    None,

    Queued,
    In_Progress,
    Rendered,
    Processed,
}

Picture :: struct
{
    using render_target: Render_Target,

    state: Picture_State,

    file_name : String_Storage(1024),
    spp       : int,

    was_autosaved  : bool,
    autosaved_name : String_Storage(1024),

    using _sdl: SDL_Picture,
}

SDL_Picture :: struct
{
    surface: ^sdl.Surface,
    texture: ^sdl.Texture,
}

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
    sdl.Keycode.RETURN    = mu.Key.RETURN,
    sdl.Keycode.BACKSPACE = mu.Key.BACKSPACE,
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

Button :: enum
{
    LMB,
    MMB,
    RMB,
}

Button_State :: struct
{
    down     : bool,
    pressed  : bool,
    released : bool,
}

Input_State :: struct
{
    mouse_p          : Vector2i,
    mouse_dp         : Vector2i,
    capture_mouse    : bool,

    buttons: [Button]Button_State,
}

button_down :: proc(input: ^Input_State, button_index: Button) -> bool
{
    return input.buttons[button_index].down
}

button_pressed :: proc(input: ^Input_State, button_index: Button) -> bool
{
    return input.buttons[button_index].pressed
}

button_released :: proc(input: ^Input_State, button_index: Button) -> bool
{
    return input.buttons[button_index].released
}

new_input_frame :: proc(input: ^Input_State)
{
    input.mouse_dp = 0

    for &button in input.buttons
    {
        button.pressed  = false
        button.released = false
    }
}

handle_button :: proc(input: ^Input_State, button_index: Button, down: bool)
{
    button := &input.buttons[button_index]
    button.pressed  =  down && down != button.down
    button.released = !down && down != button.down
    button.down     =  down
}

button_from_sdl_button_map: []Button = {
    sdl.BUTTON_LEFT   = .LMB,
    sdl.BUTTON_MIDDLE = .MMB,
    sdl.BUTTON_RIGHT  = .RMB,
}

Picture_Request :: struct
{
    w         : int,
    h         : int,
    spp       : int,
    file_name : String_Storage(1024),
}

default_picture_request :: proc(w, h: int) -> Picture_Request
{
    @(thread_local)
    next_image_index: int

    result: Picture_Request = {
        w   = w,
        h   = h,
        spp = 16,
    }
    copy_string_into_storage(&result.file_name, fmt.tprintf("image %v.png", next_image_index))
    next_image_index += 1
    return result
}

create_sdl_texture :: proc(renderer: ^sdl.Renderer, w: int, h: int, pixels: []Color_RGBA) -> (surface: ^sdl.Surface, texture: ^sdl.Texture)
{
    surface = sdl.CreateRGBSurfaceWithFormat(0, i32(w), i32(h), 
                                             32, cast(u32)sdl.PixelFormatEnum.RGBA32)

    copy(([^]Color_RGBA)(surface.pixels)[:w*h], pixels)

    texture = sdl.CreateTextureFromSurface(renderer, surface)
    return surface, texture
}

autosave_picture :: proc(picture: ^Picture)
{
    image_name := string_from_storage(&picture.file_name)

    now              := time.now()
    year, month, day := time.date(now)
    hour, min,   sec := time.clock_from_time(now)

    date_time_string := fmt.tprintf("%4i%2i%2i%2i%2i%2i", year, int(month), day, hour, min, sec)

    os.make_directory("autosaves")

    ext := path.ext(image_name)

    save_name   := fmt.tprintf("autosaves/%v_%v%v", "autosave", date_time_string, ext)
    save_name_c := strings.clone_to_cstring(save_name, context.temp_allocator)

    w      := c.int(picture.w)
    h      := c.int(picture.h)
    comp   := c.int(4)
    data   := raw_data(picture.pixels)
    stride := 4*w

    result: c.int = 0

    switch ext
    {
        case ".png" : result = stbi.write_png(save_name_c, w, h, comp, data, stride)
        case ".bmp" : result = stbi.write_bmp(save_name_c, w, h, comp, data)
        case ".tga" : result = stbi.write_tga(save_name_c, w, h, comp, data)
        case ".jpg" : result = stbi.write_jpg(save_name_c, w, h, comp, data, c.int(100))
        case ".jpeg": result = stbi.write_jpg(save_name_c, w, h, comp, data, c.int(100))
    }

    if result != 0
    {
        copy_string_into_storage(&picture.autosaved_name, save_name)
        intrinsics.atomic_store(&picture.was_autosaved, true)
    }
}

Preview_Window :: struct
{
    last_view : View,
    last_w    : int,
    last_h    : int,
}

Test_Type :: struct
{
    field: int,
}

main :: proc()
{
    info := type_info_of(Test_Type)

    test: f32

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

    max_preview_w := 3840
    max_preview_h := 2160

    backbuffer := sdl.CreateTexture(renderer, 
                                    cast(u32)sdl.PixelFormatEnum.RGBA32, 
                                    sdl.TextureAccess.STREAMING, 
                                    c.int(max_preview_w), 
                                    c.int(max_preview_h))

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
                                                 32, cast(u32)sdl.PixelFormatEnum.RGBA32)
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
    // Editor State
    //

    editor: Editor_State
    init_editor(&editor, window_w, window_h)

    //
    // Initialize Default Scene
    //

    scene: Scene

    sun := &scene.sun
    sun.d     = normalize(Vector3{0.2, 0.8, 0.3})
    sun.color = Vector3{1.0, 1.0, 1.0}

    {
        material := add_material(&scene, { albedo = { 1.0, 0.5, 0.2 }, reflectiveness = 0.5 })
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
        material := add_material(&scene, { kind = .Translucent, albedo = { 0.01, 0.05, 0.05 }, reflectiveness = 1.0, ior = 1.57 })

        spacing := f32(20.0)

        for y := -3; y <= 3; y += 1
        {
            for x := -3; x <= 3; x += 1
            {
                p := Vector3{ f32(x)*spacing, 10.0, f32(y)*spacing }
                add_sphere(&scene, { p = p, r = 7.5, material = material })
            }
        }
    }

    primitives: [dynamic]Primitive_Holder

    for sphere in scene.spheres
    {
        append(&primitives, Primitive_Holder{ sphere = sphere })
    }

    // TODO: figure it out!
    bvh, bvh_info := build_bvh(primitives[:])
    scene.bvh        = bvh
    scene.primitives = primitives

    editor.bvh_info = bvh_info

    //
    // initialize render context
    //

    rcx: Threaded_Render_Context
    init_render_context(&rcx, { preview_w, preview_h }, max_threads=-1)

    //
    //awbdjia
    //

    preview: Preview_Window

    //
    // Input
    //

    input: Input_State

    //
    // main loop
    //

    running_time: f64 = 0.0

    now                  := time.tick_now()
    time_since_last_flip := time.tick_now()
    frame_time           := 0.0
    dt                   := 1.0 / 60.0

    last_camera: Cached_Camera

    for
    {
        quit := false

        //
        // handle input
        //

        mu_has_mouse := mu_ctx.hover_id != 0 || mu_ctx.focus_id != 0

        new_input_frame(&input)

        event: sdl.Event
        for sdl.PollEvent(&event)
        {
            mu_button_from_sdl_button :: proc(button: u8) -> (ok: bool, result: mu.Mouse)
            {
                if int(button) < len(mu_button_map)
                {
                    ok = true
                    result = mu_button_map[button]
                }

                return ok, result
            }

            mu_key_from_sdl_key :: proc(in_key: sdl.Keycode) -> (ok: bool, result: mu.Key)
            {
                key := i32(in_key) & ~i32(sdl.SCANCODE_MASK)

                if int(key) < len(mu_key_map)
                {
                    ok = true
                    result = mu_key_map[key]
                }

                return ok, result
            }

            button_from_sdl_button :: proc(button: u8) -> (result: Button, ok: bool)
            {
                if int(button) < len(button_from_sdl_button_map)
                {
                    result = button_from_sdl_button_map[button]
                    ok     = true
                }
                return result, ok
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
                    if input.capture_mouse
                    {
                        mu.input_mouse_move(&mu_ctx, 0, 0)
                    }
                    else
                    {
                        mu.input_mouse_move(&mu_ctx, event.motion.x, event.motion.y)
                    }
                    input.mouse_p.x  = i32(event.motion.x)
                    input.mouse_p.y  = i32(event.motion.y)
                    input.mouse_dp.x = i32(event.motion.xrel)
                    input.mouse_dp.y = i32(event.motion.yrel)

                case .MOUSEBUTTONDOWN:
                    if !input.capture_mouse
                    {
                        if ok, button := mu_button_from_sdl_button(event.button.button); ok
                        {
                            mu.input_mouse_down(&mu_ctx, event.button.x, event.button.y, button)
                        }
                    }

                    if button, ok := button_from_sdl_button(event.button.button); ok
                    {
                        handle_button(&input, button, true)
                    }

                case .MOUSEBUTTONUP:
                    if !input.capture_mouse
                    {
                        if ok, button := mu_button_from_sdl_button(event.button.button); ok
                        {
                            mu.input_mouse_up(&mu_ctx, event.button.x, event.button.y, button)
                        }
                    }

                    if button, ok := button_from_sdl_button(event.button.button); ok
                    {
                        handle_button(&input, button, false)
                    }

                case .KEYDOWN:
                    ok, key := mu_key_from_sdl_key(event.key.keysym.sym)
                    if ok do mu.input_key_down(&mu_ctx, key)

                case .KEYUP:
                    ok, key := mu_key_from_sdl_key(event.key.keysym.sym)
                    if ok do mu.input_key_up(&mu_ctx, key)
            }
        }

        if !mu_has_mouse && button_pressed(&input, .RMB)
        {
            input.capture_mouse = !input.capture_mouse
            sdl.SetRelativeMouseMode(sdl.bool(input.capture_mouse))
            sdl.CaptureMouse        (sdl.bool(input.capture_mouse))
            if !input.capture_mouse
            {
                sdl.WarpMouseInWindow(window, i32(window_w / 2), i32(window_h / 2))
            }
        }

        //
        // ??
        //

        debug_ray_primitive: ^Primitive
        debug_ray_t: f32
        debug_ray_info: Ray_Debug_Info

        if !mu_has_mouse && button_down(&input, .LMB)
        {
            uv := Vector2{f32(input.mouse_p[0]) / f32(window_w), 1.0 - f32(input.mouse_p[1]) / f32(window_h)}
            ray := ray_from_camera_uv(last_camera, uv)
            prev_allocator := context.allocator
            context.allocator = context.temp_allocator
            debug_ray_primitive, debug_ray_t = intersect_scene_accelerated_impl(
                &scene, ray, EARLY_OUT=false, WRITE_DEBUG_INFO=true, debug=&debug_ray_info)
            context.allocator = prev_allocator
        }

        //
        // tick editor
        //

        tick_editor(&editor, &input)

        //
        // do editor UI
        //

        mu.begin(&mu_ctx)

        if mu.window(&mu_ctx, "Odin RT Editor", mu.Rect{ 10, 10, 320, i32(window_h) - 20 })
        {
            do_editor_ui(&mu_ctx, input, &editor)
        }

        mu.end(&mu_ctx)

        //
        // display most recent frame
        //

        lock_texture :: proc(texture: ^sdl.Texture) -> Render_Target
        {
            size: sdl.Point
            sdl.QueryTexture(texture, nil, nil, &size.x, &size.y)

            pixels_raw : rawptr
            pitch_raw  : c.int
            sdl.LockTexture(texture, nil, &pixels_raw, &pitch_raw)

            pitch  := int(pitch_raw / 4)
            pixels := ([^]Color_RGBA)(pixels_raw)[:int(size.y)*pitch]

            render_target := Render_Target{
                w      = int(size.x),
                h      = int(size.y),
                pitch  = pitch,
                pixels = pixels,
            }

            return render_target
        }

        unlock_texture :: proc(texture: ^sdl.Texture)
        {
            sdl.UnlockTexture(texture)
        }

        if picture := editor.picture_in_progress; picture != nil
        {
            if intrinsics.atomic_load(&picture.state) == .Rendered
            {
                editor.picture_being_shown = picture
                editor.picture_in_progress = nil
                editor.picture_shown_timer = 4.0

                // Prep picture for display
                picture.surface, picture.texture = create_sdl_texture(renderer, picture.w, picture.h, picture.pixels)

                if intrinsics.atomic_compare_exchange_strong(&picture.state, .Rendered, .Processed) != .Rendered
                {
                    panic("Someone wrote really bad threading code.")
                }
            }
        }

        shown_w := preview_w
        shown_h := preview_h
        
        if picture := editor.picture_in_progress; picture != nil
        {
            dst := lock_texture(backbuffer)

            copy_render_target(&dst, &picture.render_target)

            unlock_texture(backbuffer)

            shown_w = picture.w
            shown_h = picture.h
        }
        else if frame_available(&rcx)
        {

            dst := lock_texture(backbuffer)

            copied, w, h := copy_latest_frame(&rcx, &dst)

            if copied
            {
                shown_w, preview_w = w, w
                shown_h, preview_h = h, h
            }

            unlock_texture(backbuffer)

            frame_duration := time.tick_lap_time(&time_since_last_flip)
            frame_time      = time.duration_seconds(frame_duration)
        }

        sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
        sdl.RenderSetClipRect(renderer, nil)

        show_rect := sdl.Rect{ 0, 0, i32(shown_w), i32(shown_h) }
        sdl.RenderCopy(renderer, backbuffer, &show_rect, nil)

        editor.render_time = frame_time

        //
        // update scene
        //

        // scene_modified(&scene)
        // moving_sphere.p.y = 25.0 + 7.5*math.sin(running_time)

        //
        // dispatch new frame
        //

        origin := Vector3{ 
            f32(100.0*math.cos(0.1*running_time)),
            f32(60.0 + 20.0*math.cos(0.17*running_time)), 
            f32(100.0*math.sin(0.1*running_time)),
        }
        target    := Vector3{ 0.0, 15.0, 0.0 }
        direction := target - origin
        aspect    := f32(window_w) / f32(window_h)

        camera: Camera = ---

        if input.capture_mouse
        {
            editor.preview_camera.origin = origin
            camera = camera_from_controller(editor.preview_camera, fov=editor.fov, aspect=aspect)
        }
        else
        {
            camera = Camera{
                origin    = origin,
                direction = direction,
                fov       = editor.fov,
                aspect    = f32(preview_w) / f32(preview_h),
            }
        }

        view := View{
            scene      = &scene,
            camera     = compute_cached_camera(camera),
            view_mode  = editor.view_mode,
            show_flags = editor.show_flags,
        }

        last_camera = view.camera

        if can_dispatch_frame(&rcx)
        {
            if sm.len(editor.submitted_picture_requests) > 0
            {
                request := sm.pop_front(&editor.submitted_picture_requests)

                picture := new(Picture)
                picture.render_target = allocate_render_target({request.w, request.h})
                picture.file_name     = request.file_name
                picture.spp           = request.spp
                append(&editor.pictures, picture)

                editor.picture_in_progress = picture

                picture_camera := Camera{
                    origin    = origin,
                    direction = direction,
                    fov       = editor.fov,
                    aspect    = f32(picture.w) / f32(picture.h),
                }

                picture_view := View{
                    scene      = &scene,
                    camera     = compute_cached_camera(picture_camera),
                    view_mode  = editor.view_mode,
                    show_flags = editor.show_flags,
                }

                dispatched, _ := dispatch_picture(&rcx, picture_view, picture)
                assert(dispatched)
            }
            else
            {
                next_preview_w := int(f32(window_w)*0.25)
                next_preview_h := int(f32(window_h)*0.25)

                scene_or_view_changed := 
                    preview.last_view != view || view.scene.was_modified;

                if !scene_or_view_changed
                {
                    scale := editor.preview_resolution_scale
                    next_preview_w = int(f32(window_w)*scale)
                    next_preview_h = int(f32(window_h)*scale)
                }

                preview_res_changed :=
                    preview.last_w != next_preview_w ||
                    preview.last_h != next_preview_h

                needs_clear := scene_or_view_changed || preview_res_changed

                dispatch_frame(&rcx, view, next_preview_w, next_preview_h, needs_clear=needs_clear);

                preview.last_w          = next_preview_w
                preview.last_h          = next_preview_h
                preview.last_view       = view
                view.scene.was_modified = false
            }
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

        if .Draw_BVH in editor.show_flags || len(debug_ray_info.nodes_tried) > 0
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
                visited: [dynamic]BVH_Visitor_Args
                visited.allocator = context.temp_allocator

                visit_bvh(&scene.bvh, &visited, proc(args: BVH_Visitor_Args)
                {
                    visited := (^[dynamic]BVH_Visitor_Args)(args.userdata)
                    append(visited, args)
                })

                #reverse for args in visited
                {
                    node := args.node

                    max_depth := 10
                    if editor.draw_bvh_depth == -1 || editor.draw_bvh_depth == args.depth
                    {
                        color := debug_color(args.depth)

                        p, r := rect3_get_position_radius(node.bounds)
                        draw_box(&line_renderer, color, p, r)
                    }
                }
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

        if picture := editor.picture_being_shown; picture != nil
        {
            aspect := f32(picture.w) / f32(picture.h)
            show_h := window_h / 4
            show_w := int(math.round(f32(show_h)*aspect))

            dst_rect: sdl.Rect = {
                i32(window_w - show_w - 32),
                i32(window_h - show_h - 32),
                i32(show_w),
                i32(show_h),
            }
            sdl.RenderCopy(renderer, picture.texture, nil, &dst_rect)
        }

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

        if picture := editor.hovered_picture; picture != nil
        {
            aspect := f32(picture.w) / f32(picture.h)
            show_h := window_h / 4
            show_w := int(math.round(f32(show_h)*aspect))

            show_x := int(input.mouse_p.x)
            show_y := int(input.mouse_p.y)

            if show_y + show_h > window_h
            {
                show_y -= show_h
            }

            dst_rect: sdl.Rect = {
                i32(show_x),
                i32(show_y),
                i32(show_w),
                i32(show_h),
            }
            sdl.RenderCopy(renderer, picture.texture, nil, &dst_rect)
        }

        //
        // present
        //

        sdl.RenderPresent(renderer)

        //
        // end of loop guff
        //

        if !editor.pause_animations && is_realtime(&rcx)
        {
            running_time += dt
        }

        dt_hires := time.tick_lap_time(&now)
        dt = math.min(1.0 / 15.0, time.duration_seconds(dt_hires))
        editor.editor_dt = dt

        free_all(context.temp_allocator)

        if quit
        {
            break
        }
    }

    safely_terminate_render_context(&rcx)
}
