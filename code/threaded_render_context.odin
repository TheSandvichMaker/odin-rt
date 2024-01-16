package rt

import "core:math"
import "core:intrinsics"
import "core:sync"
import "core:os"
import "core:thread"
import "core:fmt"

Threaded_Render_Frame :: struct
{
    scene        : Scene,
    camera       : Cached_Camera,
    frame_buffer : Render_Target,

    tile_size_x: int,
    tile_size_y: int,
    tile_count_x: int,
    tile_count_y: int,
    total_tile_count: int,

    /* atomic */
    next_tile_index    : int,
    retired_tile_count : int,
}

Threaded_Render_Context :: struct
{
    cond  : sync.Cond,
    mutex : sync.Mutex,

    threads: [dynamic]^thread.Thread,

    frames: [3]Threaded_Render_Frame,

    exit          : bool,
    frame_read    : u64,
    frame_write   : u64,
    frame_display : u64,

    last_frame_displayed : u64,
}

Per_Thread_Render_Data :: struct
{
    ctx: ^Threaded_Render_Context,
}

init_render_context :: proc(ctx: ^Threaded_Render_Context, resolution: [2]int, max_threads := -1)
{
    // TODO: Handle context re-initialization

    ctx^ = {}

    ctx.frame_read    = 1
    ctx.frame_write   = 1
    ctx.frame_display = 0

    for &frame in ctx.frames
    {
        frame.frame_buffer = allocate_render_target(resolution)
    }

    core_count := os.processor_core_count()

    threads_to_spawn := core_count - 1

    if max_threads > 0 
    {
        if threads_to_spawn > max_threads
        {
            threads_to_spawn = max_threads
        }
    }

    for i := 0; i < threads_to_spawn; i += 1
    {
        data := Per_Thread_Render_Data{
            ctx = ctx,
        }

        append(&ctx.threads, thread.create_and_start_with_poly_data(data, render_thread_proc))
    }
}

render_thread_proc :: proc(data: Per_Thread_Render_Data)
{
    ctx := data.ctx;

    outer_loop:
    for
    {
        sync.mutex_lock(&ctx.mutex)

        if intrinsics.atomic_load(&ctx.exit)
        {
            sync.mutex_unlock(&ctx.mutex)
            break outer_loop
        }

        for
        {
            read  := intrinsics.atomic_load(&ctx.frame_read)
            write := intrinsics.atomic_load(&ctx.frame_write)

            if read < write
            {
                break
            }
            else
            {
                sync.cond_wait(&ctx.cond, &ctx.mutex)
            }
        }

        frame_index := intrinsics.atomic_load(&ctx.frame_read)

        sync.mutex_unlock(&ctx.mutex)

        frame := &ctx.frames[frame_index % len(ctx.frames)]
        camera        := frame.camera
        scene         := &frame.scene
        render_target := &frame.frame_buffer

        w := render_target.w
        h := render_target.h
        pixels := render_target.pixels

        tile_w := frame.tile_size_x
        tile_h := frame.tile_size_y

        tile_count_x := frame.tile_count_x
        tile_count_y := frame.tile_count_y

        params := Render_Params{
            camera      = camera,
            scene       = scene,
            frame_index = frame_index,
        }

        tile_render:
        for
        {
            tile_index := intrinsics.atomic_add(&frame.next_tile_index, 1)

            if tile_index >= frame.total_tile_count
            {
                // all work for this frame has been taken up by existing threads
                if tile_index == frame.total_tile_count 
                {
                    intrinsics.atomic_add(&ctx.frame_read, 1)
                }

                break tile_render
            }

            tile_index_x := tile_index % tile_count_x
            tile_index_y := tile_index / tile_count_x

            tile_x0 := tile_index_x*tile_w
            tile_y0 := tile_index_y*tile_h
            tile_x1 := tile_x0 + tile_w
            tile_y1 := tile_y0 + tile_h

            render_tile(params, render_target, tile_x0, tile_x1, tile_y0, tile_y1)

            retired_tile_count := intrinsics.atomic_add(&frame.retired_tile_count, 1) + 1
            assert(retired_tile_count <= frame.total_tile_count)

            if retired_tile_count == frame.total_tile_count
            {
                // frame is complete - retire frame
                for
                {
                    // SWAP_DISCARD style logic
                    new_frame_index := intrinsics.atomic_compare_exchange_strong(&ctx.frame_display, 
                                                                                 frame_index - 1, frame_index)
                    if new_frame_index >= frame_index
                    {
                        break;
                    }
                }
            }
        }
    }
}

frames_in_flight :: proc(ctx: ^Threaded_Render_Context) -> u64
{
    sync.mutex_guard(&ctx.mutex)

    read  := intrinsics.atomic_load(&ctx.frame_read)
    write := intrinsics.atomic_load(&ctx.frame_write)
    in_flight := write - read
    return in_flight
}

maybe_dispatch_frame :: proc(ctx: ^Threaded_Render_Context, view: View) -> (dispatched: bool, frame_index: u64)
{
    sync.mutex_guard(&ctx.mutex)

    display := intrinsics.atomic_load(&ctx.frame_display)
    write   := intrinsics.atomic_load(&ctx.frame_write)
    in_flight := write - display
    if in_flight < 2
    {
        write_frame := &ctx.frames[write % len(ctx.frames)]
        write_frame.camera = view.camera
        deep_copy_scene(&write_frame.scene, view.scene)

        {
            using write_frame

            w := frame_buffer.w
            h := frame_buffer.w

            tile_size_x        = 64
            tile_size_y        = 64
            tile_count_x       = (w + tile_size_x - 1) / tile_size_x
            tile_count_y       = (h + tile_size_y - 1) / tile_size_y
            total_tile_count   = tile_count_x*tile_count_y
            next_tile_index    = 0
            retired_tile_count = 0
        }

        dispatched  = true
        frame_index = intrinsics.atomic_add(&ctx.frame_write, 1)

        sync.cond_broadcast(&ctx.cond)
    }

    return dispatched, frame_index
}

maybe_copy_latest_frame :: proc(ctx: ^Threaded_Render_Context, dst: ^Render_Target) -> (copied: bool)
{
    sync.mutex_guard(&ctx.mutex)

    display_frame_index := intrinsics.atomic_load(&ctx.frame_display)
    last_frame_displayed := ctx.last_frame_displayed

    if last_frame_displayed < display_frame_index
    {
        dst_w      := dst.w
        dst_h      := dst.h
        dst_pitch  := dst.pitch
        dst_pixels := dst.pixels

        src_frame  := ctx.frames[display_frame_index % len(ctx.frames)].frame_buffer
        src_w      := src_frame.w
        src_h      := src_frame.h
        src_pitch  := src_frame.pitch
        src_pixels := src_frame.pixels

        if dst_w == src_h ||
           dst_h == src_h
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

            ctx.last_frame_displayed = display_frame_index
            copied = true

            fmt.printf("showed frame: %v\n", display_frame_index);
        }
    }

    return copied
}

safely_terminate_render_context :: proc(ctx: ^Threaded_Render_Context)
{
    sync.mutex_lock(&ctx.mutex)
    intrinsics.atomic_exchange(&ctx.exit, true)
    sync.mutex_unlock(&ctx.mutex)

    sync.cond_broadcast(&ctx.cond);
    thread.join_multiple(..ctx.threads[:])
}
