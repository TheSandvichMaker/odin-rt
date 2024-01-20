package rt

import "core:thread"

when ODIN_OS != .Windows 
{

    _set_thread_description :: proc(t: ^thread.Thread, name: string)
    {
    }

}

set_thread_description :: proc(t: ^thread.Thread, name: string)
{
    _set_thread_description(t, name)
}
