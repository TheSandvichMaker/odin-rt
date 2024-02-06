package rt

import "core:strings"
import "core:runtime"
import "core:reflect"
import "core:fmt"
import "core:intrinsics"
import "core:strconv"
import "core:math"
import "core:math/bits"
import mu "vendor:microui"

mu_slider_int :: proc(
    ctx        : ^mu.Context, 
    value      : ^int, 
    low        :  int, 
    high       :  int, 
    fmt_string :  string = "%.0f", 
    opt        :  mu.Options = {.ALIGN_CENTER},
) -> mu.Result_Set
{
    f := f32(value^)

    mu.push_id(ctx, uintptr(value))
    result := mu.slider(ctx, &f, f32(low), f32(high), 1.0, fmt_string, opt)
    mu.pop_id(ctx)

    value ^= int(f)

    return result
}

mu_number_int :: proc(
    ctx        : ^mu.Context, 
    value      : ^int, 
    fmt_string :  string = "%.0f", 
    opt        :  mu.Options = {.ALIGN_CENTER},
) -> mu.Result_Set
{
    f := f32(value^)

    mu.push_id(ctx, uintptr(value))
    result := mu.number(ctx, &f, 1.0, fmt_string, opt)
    mu.pop_id(ctx)

    value ^= int(f)

    return result
}

mu_struct :: proc(ctx: ^mu.Context, s: ^$T)
{
    info := type_info_of(T)
    mu_struct_inner(ctx, s, info)
}

UI_Notes_Int :: struct
{
    ui_min : Maybe(i64),
    ui_max : Maybe(i64),
}

parse_ui_notes_int :: proc(tag: string) -> UI_Notes_Int
{
    result: UI_Notes_Int

    parse_int_tag :: proc(tag: string, key: string) -> Maybe(i64)
    {
        tag := reflect.Struct_Tag(tag)
        if value, ok := reflect.struct_tag_lookup(tag, key); ok
        {
            if parsed, ok := strconv.parse_i64((string)(value)); ok
            {
                return parsed
            }
        }

        return nil
    }

    result.ui_min = parse_int_tag(tag, "ui_min")
    result.ui_max = parse_int_tag(tag, "ui_max")

    return result
}

UI_Notes_Float :: struct
{
    ui_min  : Maybe(f64),
    ui_max  : Maybe(f64),
    ui_step : Maybe(f64),
}

mu_struct_inner :: proc(ctx: ^mu.Context, x: rawptr, info: ^runtime.Type_Info, tag := "")
{
    bytes := ([^]u8)(x)

    #partial switch v in info.variant
    {
        case runtime.Type_Info_Named:
            if .ACTIVE in mu.treenode(ctx, v.name)
            {
                mu_struct_inner(ctx, x, v.base)
            }

        case runtime.Type_Info_Struct:
            for member_info, i in v.types
            {
                mu.label(ctx, v.names[i])
                mu_struct_inner(ctx, &bytes[v.offsets[i]], member_info, v.tags[i])
            }

        case runtime.Type_Info_Integer:
            size   := info.size
            signed := v.signed

            handle_number :: proc(ctx: ^mu.Context, x: rawptr, $T: typeid, notes: UI_Notes_Int)
            {
                min := notes.ui_min.? or_else bits.I64_MIN
                max := notes.ui_max.? or_else bits.I64_MAX

                min_f32 := f32(min)
                max_f32 := f32(max)

                k := f32((^T)(x)^)
                mu.push_id(ctx, uintptr(x))
                if min > bits.I64_MIN && max < bits.I64_MAX
                {
                    mu.slider(ctx, &k, min_f32, max_f32, 1.0)
                    k = math.clamp(k, min_f32, max_f32)
                }
                else
                {
                    mu.number(ctx, &k, 1.0)
                    k = math.clamp(k, min_f32, max_f32)
                }
                mu.pop_id(ctx)
                (^T)(x)^ = T(k)
            }

            notes := parse_ui_notes_int(tag)

            if signed
            {
                switch size
                {
                    case 1: handle_number(ctx, x, i8, notes)
                    case 2: handle_number(ctx, x, i16, notes)
                    case 4: handle_number(ctx, x, i32, notes)
                    case 8: handle_number(ctx, x, i64, notes)
                    case: panic("Crazy integer size!")
                }
            }
            else
            {
                switch size
                {
                    case 1: handle_number(ctx, x, u8, notes)
                    case 2: handle_number(ctx, x, u16, notes)
                    case 4: handle_number(ctx, x, u32, notes)
                    case 8: handle_number(ctx, x, u64, notes)
                    case: panic("Crazy integer size!")
                }
            }

        case runtime.Type_Info_Float:
            size := info.size

            handle_float :: proc(ctx: ^mu.Context, x: rawptr, $T: typeid)
            {
                k := f32((^T)(x)^)
                mu.push_id(ctx, uintptr(x))
                mu.number(ctx, &k, 0.001)
                mu.pop_id(ctx)
                (^T)(x)^ = T(k)
            }

            switch size
            {
                case 2: handle_float(ctx, x, f16)
                case 4: handle_float(ctx, x, f32)
                case 8: handle_float(ctx, x, f64)
                case: panic("Crazy float size!")
            }
    }
}

mu_flags :: proc(mu_ctx: ^mu.Context, flags: bit_set[$T]) -> bit_set[T]
{
    flags := flags

    type_info := runtime.type_info_base(type_info_of(T))
    if enum_info, ok := type_info.variant.(runtime.Type_Info_Enum); ok
    {
        for _, i in enum_info.names
        {
            name  := enum_info.names [i]
            value := enum_info.values[i]
            state := T(value) in flags
            mu.checkbox(mu_ctx, name, &state)
            flags = set_flag(flags, T(value), state)
        }
    }
    
    return flags
}

mu_enum_selection :: proc(mu_ctx: ^mu.Context, $T: typeid) -> (changed: bool, result: T)
{
    type_info := type_info_of(T)
    if named_info, ok := type_info.variant.(runtime.Type_Info_Named); ok
    {
        if enum_info, ok := named_info.base.variant.(runtime.Type_Info_Enum); ok
        {
            for _, i in enum_info.names
            {
                name  := enum_info.names[i]
                value := enum_info.values[i]
                if .SUBMIT in mu.button(mu_ctx, name)
                {
                    return true, T(value)
                }
            }
        }
    }

    return false, T{}
}

