class_name Biquad
extends RefCounted

## Биквадратный IIR-фильтр (Transposed Direct Form II). Используется как антиалиасинговый ФНЧ
## перед понижением частоты в LinearResampler. Состояние (z1/z2) хранится между семплами,
## поэтому фильтр непрерывен через границы буферов захвата.
##
## Коэффициенты — по «cookbook» Роберта Бристоу-Джонсона. Для крутого среза биквады каскадят
## (например, 4-й порядок Баттерворта = два биквада с разными Q).

var _b0 := 1.0
var _b1 := 0.0
var _b2 := 0.0
var _a1 := 0.0
var _a2 := 0.0
var _z1 := 0.0
var _z2 := 0.0


## ФНЧ: fs — частота дискретизации, fc — частота среза (Гц), q — добротность.
static func lowpass(fs: float, fc: float, q: float) -> Biquad:
	var f := Biquad.new()
	var w0 := TAU * fc / fs
	var cos_w0 := cos(w0)
	var alpha := sin(w0) / (2.0 * q)
	var b0 := (1.0 - cos_w0) * 0.5
	var b1 := 1.0 - cos_w0
	var b2 := (1.0 - cos_w0) * 0.5
	var a0 := 1.0 + alpha
	var a1 := -2.0 * cos_w0
	var a2 := 1.0 - alpha
	f._b0 = b0 / a0
	f._b1 = b1 / a0
	f._b2 = b2 / a0
	f._a1 = a1 / a0
	f._a2 = a2 / a0
	return f


func process_sample(x: float) -> float:
	var y := _b0 * x + _z1
	_z1 = _b1 * x - _a1 * y + _z2
	_z2 = _b2 * x - _a2 * y
	return y
