package rt

import "core:mem"
import "core:mem/virtual"

Arena      :: virtual.Arena
Arena_Temp :: virtual.Arena_Temp

temp_arena :: proc() -> ^Arena
{
    result := (^Arena)(context.temp_allocator.data) // DANGER!!
    return result
}

@(deferred_out = temp_scoped_end)
temp_scoped :: proc() -> Arena_Temp
{
    return virtual.arena_temp_begin(temp_arena())
}

temp_scoped_end :: proc(temp: Arena_Temp)
{
    virtual.arena_temp_end(temp)
}
