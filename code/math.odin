package rt

import "core:math"
import "core:math/linalg"

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

Vector2i :: [2]i32
Vector3i :: [3]i32
Vector4i :: [4]i32

dot       :: linalg.dot
cross     :: linalg.cross
normalize :: linalg.normalize
reflect   :: linalg.reflect

vector2_cast :: proc "contextless" ($E: typeid, source: [2]$T) -> [2]E
{
    result: [2]E = { cast(E) source.x, cast(E) source.y }
    return result
}

vector3_cast :: proc "contextless" ($E: typeid, source: [3]$T) -> [3]E
{
    result: [3]E = { cast(E) source.x, cast(E) source.y, cast(E) source.z }
    return result
}

vector4_cast :: proc "contextless" ($E: typeid, source: [4]$T) -> [4]E
{
    result: [4]E = { cast(E) source.x, cast(E) source.y, cast(E) source.z, cast(E) source.w }
    return result
}

vector_cast :: proc {
    vector2_cast,
    vector3_cast,
    vector4_cast,
}

Color_RGBA :: struct
{
    a: u8,
    b: u8,
    g: u8,
    r: u8,
}

color_rgb :: proc(r, g, b: u8) -> Color_RGBA
{
    return { 255, b, g, r }
}

color_rgba :: proc(r, g, b, a: u8) -> Color_RGBA
{
    return { a, b, g, r }
}

srgb_from_linear :: proc(lin: Vector3) -> Vector3
{
    return Vector3{
        math.sqrt(lin.x),
        math.sqrt(lin.y),
        math.sqrt(lin.z),
    }
}

rgba8_from_color :: proc(in_color: Vector3, to_srgb := true) -> Color_RGBA
{
    result: Color_RGBA 

    color := to_srgb ? srgb_from_linear(in_color) : in_color;

    using result
    r = u8(255.0*color.x)
    g = u8(255.0*color.y)
    b = u8(255.0*color.z)
    a = 255

    return result
}

@(require_results)
vector3_abs :: proc "contextless" (x: [3]f32) -> [3]f32
{
    result := [3]f32{math.abs(x.x), math.abs(x.y), math.abs(x.z)}
    return result
}

@(require_results)
min3 :: proc "contextless" (x: [3]f32) -> f32
{
    return min(x.x, min(x.y, x.z))
}

@(require_results)
max3 :: proc "contextless" (x: [3]f32) -> f32
{
    return max(x.x, max(x.y, x.z))
}

@(require_results)
schlick_fresnel :: proc "contextless" (cos_theta: f32) -> f32
{
    x      := 1.0 - cos_theta
    x2     := x*x
    result := x2*x2*x
    return result
}
