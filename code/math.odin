package rt

import "core:math"
import "core:math/linalg"

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

dot       :: linalg.dot
cross     :: linalg.cross
normalize :: linalg.normalize
reflect   :: linalg.reflect

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

