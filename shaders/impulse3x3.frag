// impulse3x3.frag — PLAN M4a: remove salt-and-pepper speckle, i.e. random per-frame impulse
// noise that the VA denoise leaves behind (~0.15% of pixels at night, 2026-11-11 sweep).
// 3x3 per-channel median (min/max exchange network), applied only where the centre pixel's
// luma differs from the median's by more than the uniform thresh (0.06 = 15/255), so flat areas, edges and detail
// 2+ pixels wide pass through untouched (1-pixel-wide high-contrast lines do not; docs/EXPLAIN-impulse3x3.md). For gst glshader: tex/width/height are set by glshader; thresh via
// uniforms="uniforms,thresh=(float)0.06" (unset = 0.0 = full median).
// cam-enhance.sh flattens this file to one line for LOOPBACK_SOURCE: so NO preprocessor
// lines (#...), NO quote characters, and comments only on lines starting with //.
precision highp float;
varying vec2 v_texcoord;
uniform sampler2D tex;
uniform float width;
uniform float height;
uniform float thresh;
void s2(inout vec3 a, inout vec3 b) { vec3 t = a; a = min(t, b); b = max(t, b); }
void main () {
  vec2 d = vec2(1.0 / width, 1.0 / height);
  vec4 c = texture2D(tex, v_texcoord);
  vec3 p0 = texture2D(tex, v_texcoord + vec2(-d.x, -d.y)).rgb;
  vec3 p1 = texture2D(tex, v_texcoord + vec2(0.0, -d.y)).rgb;
  vec3 p2 = texture2D(tex, v_texcoord + vec2(d.x, -d.y)).rgb;
  vec3 p3 = texture2D(tex, v_texcoord + vec2(-d.x, 0.0)).rgb;
  vec3 p4 = c.rgb;
  vec3 p5 = texture2D(tex, v_texcoord + vec2(d.x, 0.0)).rgb;
  vec3 p6 = texture2D(tex, v_texcoord + vec2(-d.x, d.y)).rgb;
  vec3 p7 = texture2D(tex, v_texcoord + vec2(0.0, d.y)).rgb;
  vec3 p8 = texture2D(tex, v_texcoord + vec2(d.x, d.y)).rgb;
  s2(p1, p2); s2(p4, p5); s2(p7, p8); s2(p0, p1); s2(p3, p4); s2(p6, p7);
  s2(p1, p2); s2(p4, p5); s2(p7, p8); s2(p0, p3); s2(p5, p8); s2(p4, p7);
  s2(p3, p6); s2(p1, p4); s2(p2, p5); s2(p4, p7); s2(p4, p2); s2(p6, p4);
  s2(p4, p2);
  float dev = abs(dot(c.rgb - p4, vec3(0.299, 0.587, 0.114)));
  gl_FragColor = vec4(dev > thresh ? p4 : c.rgb, c.a);
}
