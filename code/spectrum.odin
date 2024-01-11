package rt

SAMPLED_LAMBDA_START  :: 400.0
SAMPLED_LAMBDA_END    :: 700.0
SPECTRAL_SAMPLE_COUNT :: 60
Sampled_Spectrum :: distinct [SPECTRAL_SAMPLE_COUNT]f32

// things needed:
// - XYZ to Spectrum
// - Spectrum to XYZ
// - RGB to Spectrum
// - Spectrum to RGB

// By virtue of array programming, I think the rest will work out by itself

// Also:
// - Find some spectral measurements of different materials
