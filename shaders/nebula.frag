#version 460 core
// Kozmik zemin: derin siyah, çok soluk galaksi tozu (simgedeki halkayla aynı eğimde çapraz bant),
// kenar karartma ve tam çözünürlükte titreşimsiz gren (koyu gradyanın bantlanmasını da örter).
// Pencere boyunda bir kez çizilir, sonra yalnız kaydırılır (bkz. aurora_background.dart).
precision highp float;
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;  // hedef görüntünün piksel boyutu
uniform float uSeed; // toz deseni

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 px = FlutterFragCoord().xy;
  vec2 uv = px / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);

  // Halkanın eğimiyle (-20°) çapraz, ortanın biraz üstünden geçen toz bandı.
  float ang = -0.35;
  vec2 r = vec2(cos(ang) * p.x + sin(ang) * p.y, -sin(ang) * p.x + cos(ang) * p.y);
  float band = exp(-pow((r.y + 0.05) / 0.22, 2.0));
  float n = fbm(p * 3.0 + uSeed);
  float fine = fbm(p * 11.0 - uSeed * 1.7);
  float dust = band * smoothstep(0.30, 0.85, n) * (0.5 + 0.5 * fine);
  // İnce koyu damarlar (toz şeritleri).
  dust *= 0.6 + 0.4 * smoothstep(0.42, 0.58, fbm(r * vec2(2.2, 8.0) + 3.1));

  vec3 bg = vec3(0.0157, 0.0157, 0.0235); // AppColors.bg
  vec3 col = bg + vec3(0.80, 0.84, 1.0) * dust * 0.11;
  // Bütün ekranda çok sönük ikinci toz.
  col += vec3(0.70, 0.75, 0.90) * pow(fbm(p * 1.7 + 7.3), 3.0) * 0.03;

  // Kenar karartma: içerik ortada öne çıksın.
  float vig = smoothstep(1.05, 0.25, length(p * vec2(0.9, 1.1)));
  col *= 0.55 + 0.45 * vig;

  // Gren: piksel başına ±2/255.
  col += (hash(floor(px)) - 0.5) * (4.0 / 255.0);
  fragColor = vec4(max(col, vec3(0.0)), 1.0);
}
