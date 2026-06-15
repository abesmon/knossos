shader_type spatial;
// Зеркало рисуется как обычная плоскость, но вместо освещения берёт цвет из текстуры
// отражения (её рендерит отдельная камера в SubViewport, см. scripts/vrweb_mirror.gd).
// unshaded — на зеркало не влияет свет сцены, оно само себе картинка.
render_mode unshaded, cull_back;

// Текстура отражения = кадр SubViewport, отрендеренный отражённой камерой в том же
// разрешении, что и основной экран. Поэтому сэмплируем её по SCREEN_UV — экранной
// позиции фрагмента зеркала: туда же отражённая камера спроецировала отражённую точку.
uniform sampler2D reflection_tex : source_color, hint_default_black, filter_linear;
// Отражённая камера строится через look_at (правый базис), поэтому изображение выходит
// горизонтально перевёрнутым относительно настоящего зеркала — компенсируем флипом X.
uniform bool flip_x = true;
uniform bool flip_y = false;
// Лёгкий оттенок/затемнение стекла (1,1,1 — чистое зеркало).
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);

void fragment() {
	vec2 uv = SCREEN_UV;
	if (flip_x) {
		uv.x = 1.0 - uv.x;
	}
	if (flip_y) {
		uv.y = 1.0 - uv.y;
	}
	ALBEDO = texture(reflection_tex, uv).rgb * tint;
}
