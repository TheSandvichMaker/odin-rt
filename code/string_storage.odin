package rt

import "core:mem"

String_Storage :: struct($N: int) where N > 0
{
    buffer : [N]u8,
    len    : int,
}

string_from_storage :: proc(storage: String_Storage($N)) -> string
{
    return transmute(string)storage.buffer[:storage.len]
}

copy_string_into_storage :: proc(storage: ^String_Storage($N), str: string)
{
    copy_len := min(len(str), len(storage.buffer))
    copy(storage.buffer[:], str[:copy_len])
}
