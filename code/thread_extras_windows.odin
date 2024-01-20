package rt

import "core:thread"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="stdcall")
foreign kernel32
{
    SetThreadDescription :: proc(
      hThread: win32.HANDLE,
      lpThreadDescription: win32.LPCWSTR
    ) -> win32.DWORD ---
}

_set_thread_description :: proc(t: ^thread.Thread, name: string)
{
    wide_name := win32.utf8_to_wstring(name)
    SetThreadDescription(t.win32_thread, wide_name)
}
