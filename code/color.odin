package rt

import "core:math"

debug_color :: proc(index: int) -> (result: Vector3)
{
    bits := (index % 6) + 1
    result.x = (bits & 0x1) != 0 ? 1.0 : 0.0
    result.y = (bits & 0x2) != 0 ? 1.0 : 0.0
    result.z = (bits & 0x4) != 0 ? 1.0 : 0.0
    return result
}

Lab :: distinct [3]f32

oklab_from_linear_srgb :: proc(c: Vector3) -> Lab
{
    l := 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
	m := 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
	s := 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z

    l_ := math.pow(l, 1.0 / 3.0);
    m_ := math.pow(m, 1.0 / 3.0);
    s_ := math.pow(s, 1.0 / 3.0);

    result := Lab{
        0.2104542553*l_ + 0.7936177850*m_ - 0.0040720468*s_,
        1.9779984951*l_ - 2.4285922050*m_ + 0.4505937099*s_,
        0.0259040371*l_ + 0.7827717662*m_ - 0.8086757660*s_,
    }
    return result
}

linear_srgb_from_oklab :: proc(c: Lab) -> Vector3
{
    l_ := c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
    m_ := c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
    s_ := c.x - 0.0894841775 * c.y - 1.2914855480 * c.z

    l := l_*l_*l_
    m := m_*m_*m_
    s := s_*s_*s_

    result := Vector3{
		+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    }
    return result
}

LCh :: distinct [3]f32

oklch_from_oklab :: proc(lab: Lab) -> LCh
{
    return {
        lab[0],
        math.sqrt(lab[1]*lab[1] + lab[2]*lab[2]),
        math.atan2(lab[2], lab[1]),
    }
}

oklab_from_oklch :: proc(lch: LCh) -> Lab
{
    return {
        lch[0],
        lch[1]*math.cos(lch[2]),
        lch[1]*math.sin(lch[2]),
    }
}

oklch_from_linear_srgb :: proc(srgb: Vector3) -> LCh
{
    return oklch_from_oklab(oklab_from_linear_srgb(srgb))
}

linear_srgb_from_oklch :: proc(lch: LCh) -> Vector3
{
    return linear_srgb_from_oklab(oklab_from_oklch(lch))
}

