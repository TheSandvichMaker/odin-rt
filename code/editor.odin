package rt

import    "core:fmt"
import    "core:math"
import sm "core:container/small_array"
import mu "vendor:microui"

Editor_State :: struct
{
    window_w                   : int,
    window_h                   : int,

    preview_w                  : int,
    preview_h                  : int,

    editor_dt                  : f64,
    render_time                : f64,
    max_bvh_depth              : int,

    pause_animations           : bool,
    draw_bvh                   : bool,
    draw_bvh_depth             : int,
    fov                        : f32,
    view_mode                  : View_Mode,
    show_flags                 : Show_Flags_Set,

    picture_request            : Picture_Request,
    submitted_picture_requests : sm.Small_Array(4, Picture_Request),

    picture_in_progress        : ^Picture,
    picture_shown_timer        : f64,
    picture_being_shown        : ^Picture,
    hovered_picture            : ^Picture,
    pictures                   : [dynamic]^Picture,
}

init_editor :: proc(editor: ^Editor_State, window_w, window_h, preview_w, preview_h: int)
{
    editor.view_mode       = .Lit
    editor.fov             = f32(85.0)
    editor.window_w        = window_w
    editor.window_h        = window_h
    editor.preview_w       = preview_w
    editor.preview_h       = preview_h
    editor.picture_request = default_picture_request(editor.window_w, editor.window_h)
    editor.draw_bvh_depth  = -1
}

do_editor_ui :: proc(ctx: ^mu.Context, input: Input_State, editor: ^Editor_State)
{
    if editor.picture_shown_timer > 0.0
    {
        editor.picture_shown_timer -= editor.editor_dt

        if editor.picture_shown_timer <= 0.0
        {
            editor.picture_being_shown = nil
            editor.picture_shown_timer = 0.0
        }
    }

    mu.text(ctx, fmt.tprintf("Frame time: %.02fms, fps: %.02f", editor.render_time * 1000.0, 1.0 / editor.render_time))

    mu.checkbox(ctx, "Pause Animations", &editor.pause_animations)

    if .ACTIVE in mu.header(ctx, "View Mode")
    {
        if changed, value := mu_enum_selection(ctx, View_Mode); changed
        {
            editor.view_mode = value
        }
    }

    if .ACTIVE in mu.header(ctx, "Show Flags")
    {
        mu_flags(ctx, &editor.show_flags)
    }

    if .Draw_BVH in editor.show_flags
    {
        if .ACTIVE in mu.header(ctx, "Draw BVH")
        {
            mu.label(ctx, "Show Depth")
            mu_slider_int(ctx, &editor.draw_bvh_depth, -1, editor.max_bvh_depth)
        }
    }

    mu.label(ctx, "fov")
    mu.slider(ctx, &editor.fov, 45.0, 100.0)

    request := &editor.picture_request

    mu.label(ctx, "Render Resolution W:")
    mu_number_int(ctx, &request.w)
    request.w = math.clamp(request.w, 1, 8192)

    mu.label(ctx, "Render Resolution H:")
    mu_number_int(ctx, &request.h)
    request.h = math.clamp(request.h, 1, 8192)

    mu.label(ctx, "Render Samples Per Pixel:")
    mu_number_int(ctx, &request.spp)
    request.spp = math.clamp(request.spp, 1, 8192)

    if .SUBMIT in mu.button(ctx, "Take Picture")
    {
        if sm.space(editor.submitted_picture_requests) > 0
        {
            sm.append(&editor.submitted_picture_requests, request^)
        }
    }

    editor.hovered_picture = nil

    if .ACTIVE in mu.header(ctx, "Pictures")
    {
        for picture, index in editor.pictures
        {
            file_name := string_from_storage(&picture.file_name)
            mu.push_id(ctx, uintptr(index))
            mu.button(ctx, file_name)
            if ctx.hover_id == ctx.last_id
            {
                editor.hovered_picture = picture
            }
            mu.pop_id(ctx)
        }
    }

    if editor.picture_shown_timer > 0.0
    {
        mu.text(ctx, "Showing picture...")
    }
}
