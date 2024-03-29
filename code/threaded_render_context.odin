package rt

import "core:math"
import "core:intrinsics"
import "core:sync"
import "core:os"
import "core:thread"
import "core:fmt"
import "core:time"
import "core:simd/x86"
import "core:mem/virtual"

Threaded_Render_Frame :: struct #align(64)
{
    /* atomically written to */
    using _: struct #align(64) { next_tile_index    : int }, // bill pls fix, what is this
    using _: struct #align(64) { retired_tile_count : int },
    using _: struct #align(64) { render_time_clocks : u64 },

    /* */
    arena               : Arena,

    /* read-only */
    view              : View,
    scene_cloned      : Scene,
    accum_needs_clear : bool,
    tile_size_x       : int,
    tile_size_y       : int,
    tile_count_x      : int,
    tile_count_y      : int,
    total_tile_count  : int,
    spiral_positions  : []Vector2i,

    /* read-write (non-atomic) */
    frame_buffer      : Render_Target,
    picture_target    : ^Picture,
}

Threaded_Render_Context :: struct
{
    /* guards Threaded_Render_Frame data*/
    mutex   : sync.Mutex,
    /* synchronizes render threads at frame boundaries */
    cond    : sync.Cond, // guarded by mutex
    threads : [dynamic]^thread.Thread,

    frames              : [3]Threaded_Render_Frame,
    accumulation_buffer : Accumulation_Buffer,

    exit          : bool,
    frame_read    : u64,
    frame_write   : u64,
    frame_display : u64,
    frame_sync    : u64,

    pictures_in_flight   : u64,
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

    ctx.accumulation_buffer = allocate_accumulation_buffer({3840, 2160})

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

        t := thread.create_and_start_with_poly_data(data, render_thread_proc)
        set_thread_description(t, fmt.tprintf("render thread #%v", i))

        append(&ctx.threads, t)
    }
}

can_dispatch_frame :: proc(ctx: ^Threaded_Render_Context) -> bool
{
    if ctx.pictures_in_flight > 0 do return false

    write   := intrinsics.atomic_load(&ctx.frame_write)
    display := intrinsics.atomic_load(&ctx.frame_display)
    in_flight := write - display
    return in_flight < 2
}

abandon_current_frames :: proc(ctx: ^Threaded_Render_Context)
{
    intrinsics.atomic_store(&ctx.frame_sync, intrinsics.atomic_load(&ctx.frame_write))
}

Spiral_Generator :: struct
{
    at                           : Vector2i,
    direction                    : Vector2i,
    run_left                     : i32,
    run_length                   : i32,
    runs_before_length_increase  : i32,
}

make_spiral_generator :: proc(start: Vector2i) -> Spiral_Generator
{
    gen: Spiral_Generator =
    {
        at                           = start,
        direction                    = { -1, 0 },
        run_length                   = 0,
        run_left                     = 1,
        runs_before_length_increase  = 1,
    }
    return gen
}

next_spiral_tile :: proc(gen: ^Spiral_Generator) -> Vector2i
{
    gen.run_left -= 1

    if gen.run_left == 0
    {
        gen.runs_before_length_increase -= 1

        if gen.runs_before_length_increase == 0
        {
            gen.runs_before_length_increase = 2
            gen.run_length                 += 1
        }

        gen.direction = { -gen.direction.y, gen.direction.x }
        gen.run_left  = gen.run_length
    }

    result := gen.at
    gen.at += gen.direction

    return result
}

generate_spiral_positions :: proc(
    tile_count_x: i32, 
    tile_count_y: i32, 
    allocator := context.allocator,
) -> []Vector2i
{
    tile_count := tile_count_x*tile_count_y

    result := make([]Vector2i, tile_count, allocator)

    gen := make_spiral_generator({ i32(tile_count_x / 2), i32(tile_count_y / 2) })

    tile_index: i32 = 0
    for tile_index < tile_count 
    {
        pos := next_spiral_tile(&gen)
        if pos.x >= 0           && pos.y >= 0 && 
           pos.x < tile_count_x && pos.y < tile_count_y
        {
            pos.y = tile_count_y - pos.y - 1
            result[tile_index] = pos
            tile_index += 1
        }
    }

    return result
}

dispatch_frame :: proc(ctx: ^Threaded_Render_Context, view: View, w, h: int, needs_clear := false) -> (dispatched: bool, frame_index: u64)
{
    sync.mutex_guard(&ctx.mutex)

    write   := intrinsics.atomic_load(&ctx.frame_write)
    display := intrinsics.atomic_load(&ctx.frame_display)
    in_flight := write - display
    if in_flight < 2
    {
        write_frame := &ctx.frames[write % len(ctx.frames)]

        write_frame.view = view
        deep_copy_scene(&write_frame.scene_cloned, view.scene)

        write_frame.view.scene = &write_frame.scene_cloned

        frame_buffer_needs_resize  := write_frame.frame_buffer.w != w || write_frame.frame_buffer.h != h
        if frame_buffer_needs_resize
        {
            delete_render_target(&write_frame.frame_buffer)
            write_frame.frame_buffer = allocate_render_target({w, h})
        }

        virtual.arena_free_all(&write_frame.arena)
        write_frame.tile_size_x        = 64
        write_frame.tile_size_y        = 64
        write_frame.tile_count_x       = (w + write_frame.tile_size_x - 1) / write_frame.tile_size_x
        write_frame.tile_count_y       = (h + write_frame.tile_size_y - 1) / write_frame.tile_size_y
        write_frame.total_tile_count   = write_frame.tile_count_x*write_frame.tile_count_y
        write_frame.next_tile_index    = 0
        write_frame.retired_tile_count = 0
        write_frame.render_time_clocks = 0
        write_frame.picture_target     = nil
        write_frame.accum_needs_clear  = needs_clear || frame_buffer_needs_resize

        write_frame.spiral_positions = generate_spiral_positions(
            i32(write_frame.tile_count_x),
            i32(write_frame.tile_count_y),
            virtual.arena_allocator(&write_frame.arena),
        )

        dispatched  = true
        frame_index = intrinsics.atomic_add(&ctx.frame_write, 1)

        sync.cond_broadcast(&ctx.cond)
    }

    return dispatched, frame_index
}

dispatch_picture :: proc(ctx: ^Threaded_Render_Context, view: View, picture: ^Picture) -> (dispatched: bool, frame_index: u64)
{
    sync.mutex_guard(&ctx.mutex)

    write   := intrinsics.atomic_load(&ctx.frame_write)
    display := intrinsics.atomic_load(&ctx.frame_display)
    in_flight := write - display
    if in_flight < 2
    {
        write_frame := &ctx.frames[write % len(ctx.frames)]

        write_frame.view = view
        deep_copy_scene(&write_frame.scene_cloned, view.scene)

        write_frame.view.scene = &write_frame.scene_cloned

        w := picture.w
        h := picture.h

        virtual.arena_free_all(&write_frame.arena)
        write_frame.tile_size_x          = 64
        write_frame.tile_size_y          = 64
        write_frame.tile_count_x         = (w + write_frame.tile_size_x - 1) / write_frame.tile_size_x
        write_frame.tile_count_y         = (h + write_frame.tile_size_y - 1) / write_frame.tile_size_y
        write_frame.total_tile_count     = write_frame.tile_count_x*write_frame.tile_count_y
        write_frame.next_tile_index      = 0
        write_frame.retired_tile_count   = 0
        write_frame.render_time_clocks   = 0
        write_frame.picture_target       = picture
        write_frame.picture_target.state = .Queued

        write_frame.spiral_positions = generate_spiral_positions(
            i32(write_frame.tile_count_x),
            i32(write_frame.tile_count_y),
            virtual.arena_allocator(&write_frame.arena),
        )

        ctx.pictures_in_flight += 1
        frame_index = intrinsics.atomic_add(&ctx.frame_write, 1)

        dispatched  = true

        sync.cond_broadcast(&ctx.cond)
    }

    return dispatched, frame_index
}

render_thread_proc :: proc(data: Per_Thread_Render_Data)
{
    ctx := data.ctx;

    frame_loop:
    for
    {
        sync.mutex_lock(&ctx.mutex)

        for
        {
            if ctx.exit
            {
                sync.mutex_unlock(&ctx.mutex)
                break frame_loop
            }

            read  := ctx.frame_read
            write := ctx.frame_write

            if read < write
            {
                break
            }
            else
            {
                sync.cond_wait(&ctx.cond, &ctx.mutex)
            }
        }

        frame_index := ctx.frame_read

        sync.mutex_unlock(&ctx.mutex)

        frame := &ctx.frames[frame_index % len(ctx.frames)]
        render_target       := &frame.frame_buffer
        picture             := frame.picture_target
        accum_needs_clear   := frame.accum_needs_clear
        accumulation_buffer := &ctx.accumulation_buffer

        use_spiral_pattern := false

        if picture != nil
        {
            use_spiral_pattern = true

            render_target       = &picture.render_target
            accumulation_buffer = nil

            if picture.state == .Queued
            {
                intrinsics.atomic_compare_exchange_strong(&picture.state, .Queued, .In_Progress)
            }
        }

        w := render_target.w
        h := render_target.h
        pixels := render_target.pixels

        tile_w := frame.tile_size_x
        tile_h := frame.tile_size_y

        tile_count_x := frame.tile_count_x
        tile_count_y := frame.tile_count_y

        params := Render_Params{
            rcx                 = ctx,
            view                = frame.view,
            frame_index         = frame_index,
            render_target       = render_target, 
            accumulation_buffer = accumulation_buffer, 
            accum_needs_clear   = accum_needs_clear,
            spp                 = picture != nil ? picture.spp : 1,
        }

        clocks_spent: u64 = 0

        tile_loop:
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

                break tile_loop
            }

            tile_index_x := tile_index % tile_count_x
            tile_index_y := tile_index / tile_count_x

            if use_spiral_pattern
            {
                tile_pos := frame.spiral_positions[tile_index]
                tile_index_x = int(tile_pos.x)
                tile_index_y = int(tile_pos.y)
            }

            tile_x0 := tile_index_x*tile_w
            tile_y0 := tile_index_y*tile_h
            tile_x1 := tile_x0 + tile_w
            tile_y1 := tile_y0 + tile_h

            params.rand = random_seed(u32(tile_index_x) + 1337*u32(tile_index_y) + 69420*u32(params.frame_index))

            clocks_start := x86._rdtsc()
            render_tile(params, tile_x0, tile_x1, tile_y0, tile_y1)
            clocks_end := x86._rdtsc()

            free_all(context.temp_allocator)

            clocks_spent += clocks_end - clocks_start

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

                if accumulation_buffer != nil
                {
                    accumulation_buffer.accumulated_frame_count += u64(params.spp)
                }

                if picture != nil
                {
                    if picture.state == .In_Progress
                    {
                        prev_state := intrinsics.atomic_compare_exchange_strong(
                            &picture.state, .In_Progress, .Rendered)

                        assert(prev_state == .In_Progress)

                        intrinsics.atomic_sub(&ctx.pictures_in_flight, 1)
                        autosave_picture(picture)
                    }
                    else
                    {
                        panic("Clearly, someone wrote bad threading code")
                    }
                }
            }
        }

        intrinsics.atomic_add(&frame.render_time_clocks, clocks_spent)
    }
}

frame_available :: proc(ctx: ^Threaded_Render_Context) -> bool
{
    display_frame_index := intrinsics.atomic_load(&ctx.frame_display)
    return ctx.last_frame_displayed < display_frame_index
}

copy_latest_frame :: proc(ctx: ^Threaded_Render_Context, dst: ^Render_Target) -> (copied: bool, w: int, h: int)
{
    display_frame_index := intrinsics.atomic_load(&ctx.frame_display)
    last_frame_displayed := ctx.last_frame_displayed

    if last_frame_displayed < display_frame_index
    {
        frame := &ctx.frames[display_frame_index % len(ctx.frames)]
        src   := &frame.frame_buffer

        copied = copy_render_target(dst, src)
        w      = src.w
        h      = src.h

        if copied
        {
            ctx.last_frame_displayed = display_frame_index

            mega_cycles := f64(frame.render_time_clocks) / 1_000_000.0
            fmt.printf("showed frame: %v (mcy: %.2f)\n", display_frame_index, mega_cycles);
        }
    }

    return copied, w, h
}

is_realtime :: proc(ctx: ^Threaded_Render_Context) -> (realtime: bool)
{
    return ctx.pictures_in_flight == 0
}

safely_terminate_render_context :: proc(ctx: ^Threaded_Render_Context)
{
    sync.mutex_lock(&ctx.mutex)
    ctx.exit = true
    sync.mutex_unlock(&ctx.mutex)

    sync.cond_broadcast(&ctx.cond);
    thread.join_multiple(..ctx.threads[:])
}
