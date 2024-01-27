package rt

import "core:runtime"

peel_named :: proc(info: ^runtime.Type_Info) -> ^runtime.Type_Info
{
    if named, ok := info.variant.(runtime.Type_Info_Named); ok
    {
        return named.base
    }
    return info
}
