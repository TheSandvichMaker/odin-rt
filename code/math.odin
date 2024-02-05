package rt

import "core:math"
import "core:math/linalg"

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
f32x4   :: #simd[4]f32

@(require_results) f32x4_from_vector2 :: #force_inline proc "contextless" (v: Vector2) -> f32x4 { return { v.x, v.y } }
@(require_results) f32x4_from_vector3 :: #force_inline proc "contextless" (v: Vector3) -> f32x4 { return { v.x, v.y, v.z } }
@(require_results) f32x4_from_vector4 :: #force_inline proc "contextless" (v: Vector4) -> f32x4 { return { v.x, v.y, v.z, v.w } }
@(require_results) f32x4_from_floats  :: #force_inline proc "contextless" (x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0, w: f32 = 0.0) -> f32x4 { return { x, y, z, w } }

f32x4_from :: proc 
{
    f32x4_from_vector2,
    f32x4_from_vector3,
    f32x4_from_vector4,
    f32x4_from_floats,
}

Vector2i :: [2]i32
Vector3i :: [3]i32
Vector4i :: [4]i32

dot       :: linalg.dot
cross     :: linalg.cross
normalize :: linalg.normalize
reflect   :: linalg.reflect
refract   :: linalg.refract

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

exp_v3 :: proc(v: Vector3) -> Vector3
{
    return {
        math.exp(v.x),
        math.exp(v.y),
        math.exp(v.z),
    }
}

Color_RGBA :: struct
{
    r: u8,
    g: u8,
    b: u8,
    a: u8,
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
component_abs :: proc "contextless" (x: Vector3) -> Vector3
{
    result := Vector3{math.abs(x.x), math.abs(x.y), math.abs(x.z)}
    return result
}

@(require_results)
component_min :: proc "contextless" (a: Vector3, b: Vector3) -> Vector3
{
    result := Vector3{min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}
    return result
}

@(require_results)
component_max :: proc "contextless" (a: Vector3, b: Vector3) -> Vector3
{
    result := Vector3{max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
    return result
}

@(require_results)
min3 :: proc "contextless" (x: Vector3) -> f32
{
    return min(x.x, min(x.y, x.z))
}

@(require_results)
max3 :: proc "contextless" (x: Vector3) -> f32
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

Rect3 :: struct
{
    min: Vector3,
    max: Vector3,
}

rect3_get_position_radius :: proc(rect: Rect3) -> (p: Vector3, r: Vector3)
{
    p = 0.5*(rect.min + rect.max)
    r = 0.5*(rect.max - rect.min)
    return p, r
}

rect3_inverted_infinity :: proc() -> Rect3
{
    rect: Rect3 = {
        min = {  math.F32_MAX,  math.F32_MAX,  math.F32_MAX },
        max = { -math.F32_MAX, -math.F32_MAX, -math.F32_MAX },
    }
    return rect
}

rect3_center_radius_vec3 :: proc(p: Vector3, r: Vector3) -> (result: Rect3)
{
    result.min = p - r
    result.max = p + r
    return result
}

rect3_center_radius_scalar :: proc(p: Vector3, r: f32) -> (result: Rect3)
{
    return #force_inline rect3_center_radius_vec3(p, { r, r, r })
}

rect3_center_radius :: proc {
    rect3_center_radius_vec3,
    rect3_center_radius_scalar,
}

rect3_union :: proc(a: Rect3, b: Rect3) -> (result: Rect3)
{
    result.min = component_min(a.min, b.min)
    result.max = component_max(a.max, b.max)
    return result
}

rect3_get_dim :: proc(rect: Rect3) -> Vector3
{
    return rect.max - rect.min
}

rect3_find_largest_axis :: proc(rect: Rect3) -> int
{
    dim := rect3_get_dim(rect)

    result := 0
    if abs(dim[1]) > abs(dim[result]) do result = 1
    if abs(dim[2]) > abs(dim[result]) do result = 2
    return result
}

Xorshift32_State :: distinct u32

random_seed :: proc(seed: u32) -> Xorshift32_State
{
    return Xorshift32_State(seed == 0 ? 1 : seed)
}

random_next :: proc(state: ^Xorshift32_State) -> u32
{
	/* Algorithm "xor" from p. 4 of Marsaglia, "Xorshift RNGs" */
    x := state^
	x ~= x << 13;
	x ~= x >> 17;
	x ~= x << 5;
    state ^= x
	return u32(x)
}

random_unilateral :: proc(state: ^Xorshift32_State) -> f32
{
    x := random_next(state)
    h := u32(0x3f800000) | (x & ((1 << 24) - 1))
    f := transmute(f32)h - 1.0
    return f
}

random_unilateral_v2 :: proc(state: ^Xorshift32_State) -> Vector2
{
    return {
        random_unilateral(state),
        random_unilateral(state),
    }
}

random_unilateral_v3 :: proc(state: ^Xorshift32_State) -> Vector3
{
    return {
        random_unilateral(state),
        random_unilateral(state),
        random_unilateral(state),
    }
}

random_unilateral_v4 :: proc(state: ^Xorshift32_State) -> Vector4
{
    return {
        random_unilateral(state),
        random_unilateral(state),
        random_unilateral(state),
        random_unilateral(state),
    }
}

random_bilateral :: proc(state: ^Xorshift32_State) -> f32
{
    return 2.0*random_unilateral(state) - 1.0
}

random_bilateral_v2 :: proc(state: ^Xorshift32_State) -> Vector2
{
    return {
        random_bilateral(state),
        random_bilateral(state),
    }
}

random_bilateral_v3 :: proc(state: ^Xorshift32_State) -> Vector3
{
    return {
        random_bilateral(state),
        random_bilateral(state),
        random_bilateral(state),
    }
}

random_bilateral_v4 :: proc(state: ^Xorshift32_State) -> Vector4
{
    return {
        random_bilateral(state),
        random_bilateral(state),
        random_bilateral(state),
        random_bilateral(state),
    }
}
