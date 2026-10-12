## units.gd - the single place where shop units meet simulation units.
##
## JSON data files store SHOP units (pounds, inches, feet, rpm, mph); the
## simulation and rendering use SI (kilograms, metres, seconds, radians); the
## UI converts back on the way out. Nothing else holds a conversion constant.
class_name U

const LB_TO_KG := 0.45359237
const KG_TO_LB := 1.0 / LB_TO_KG
const IN_TO_M := 0.0254
const M_TO_IN := 1.0 / IN_TO_M
const FT_TO_M := 0.3048
const M_TO_FT := 1.0 / FT_TO_M
const MPS_TO_MPH := 2.2369362920544
const MPH_TO_MPS := 1.0 / MPS_TO_MPH
const DEG_TO_RAD := PI / 180.0
const RAD_TO_DEG := 180.0 / PI
const RPM_TO_RADPS := (2.0 * PI) / 60.0

static func lb_to_kg(lb: float) -> float: return lb * LB_TO_KG
static func kg_to_lb(kg: float) -> float: return kg * KG_TO_LB
static func in_to_m(inches: float) -> float: return inches * IN_TO_M
static func m_to_in(m: float) -> float: return m * M_TO_IN
static func ft_to_m(ft: float) -> float: return ft * FT_TO_M
static func m_to_ft(m: float) -> float: return m * M_TO_FT
static func mps_to_mph(mps: float) -> float: return mps * MPS_TO_MPH
static func deg_to_rad(d: float) -> float: return d * DEG_TO_RAD
static func rad_to_deg(r: float) -> float: return r * RAD_TO_DEG
static func rpm_to_radps(rpm: float) -> float: return rpm * RPM_TO_RADPS

## An [x, y, z] triple of feet as a Vector3 in metres (arena data is in feet).
static func ft3(a) -> Vector3: return Vector3(a[0], a[1], a[2]) * FT_TO_M
## An [x, y, z] triple of inches as a Vector3 in metres (part data is in inches).
static func in3(a) -> Vector3: return Vector3(a[0], a[1], a[2]) * IN_TO_M
## [x, y, z] as a Vector3, no conversion.
static func v3(a) -> Vector3: return Vector3(a[0], a[1], a[2])

## mm:ss for the match clock.
static func format_clock(seconds: float) -> String:
	var s := maxf(0.0, seconds)
	var m := int(floor(s / 60.0))
	var r := int(floor(fmod(s, 60.0)))
	return "%d:%02d" % [m, r]
