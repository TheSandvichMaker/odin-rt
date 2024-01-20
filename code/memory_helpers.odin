package rt

import "core:mem"
import "core:mem/virtual"

temp_arena :: proc() -> ^virtual.Arena
{
    result := (^virtual.Arena)(context.temp_allocator.data) // DANGER!!
    return result
}

@(deferred_out = temp_scoped_end)
temp_scoped :: proc() -> virtual.Arena_Temp
{
    return virtual.arena_temp_begin(temp_arena())
}

temp_scoped_end :: proc(temp: virtual.Arena_Temp)
{
    virtual.arena_temp_end(temp)
}

