package rt

import "core:runtime"

set_flag :: proc(flags: bit_set[$T], value: T, state: bool) -> bit_set[T]
{
    flags := flags

    if state do flags += {value}
    else     do flags -= {value}

    return flags
}

toggle_flag :: proc(flags: bit_set[$T], value: T) -> bit_set[T]
{
    return set_flag(flags, value, !(value in flags))
}
