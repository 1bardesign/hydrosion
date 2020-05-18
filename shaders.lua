-------------------------------------------------------------------------------
--shaders!

--finite difference average normal source
--used more than once so extracted here
local norm_src = [[
float _norm_h(Image i, vec2 uv) {
	return Texel(i, uv).r;
}

vec2 norm(Image i, vec2 res, vec2 uv) {
	vec2 o = vec2(1.0) / res;
	vec2 ox = o * vec2(1.0, 0.0);
	vec2 oy = o * vec2(0.0, 1.0);
	float hh = _norm_h(i, uv);
	return vec2(
		mix(
			_norm_h(i, uv + ox) - hh,
			hh - _norm_h(i, uv - ox),
			0.5
		),
		mix(
			_norm_h(i, uv + oy) - hh,
			hh - _norm_h(i, uv - oy),
			0.5
		)
	);
}
]]

--integrate the droplets
integrate_shader = lg.newShader([[
uniform Image u_terrain;
uniform vec2 u_terrain_res;
//old data
uniform Image u_vel;
uniform Image u_pos;
uniform Image u_volume;

uniform float u_evap_iters;

uniform float u_dissolve_rate;
uniform float u_sediment_rate;
uniform float u_max_carry_frac;

float carry_capacity(float vol, float vellen) {
	return vol * clamp(vellen, 0.25, 1.0) * u_max_carry_frac;
}

#ifdef PIXEL
]]..norm_src..[[
void effect() {
	vec2 uv = VaryingTexCoord.xy;
	//2d
	vec2 pos = Texel(u_pos, uv).xy;
	vec2 vel = Texel(u_vel, uv).xy;
	//x = water, y = sediment
	vec2 volume = Texel(u_volume, uv).xy;

	//get the slope here
	float terrain_previous = Texel(u_terrain, pos).r;
	vec2 terrain_norm = norm(u_terrain, u_terrain_res, pos);
	
	//
	float vellen = length(vel);

	//velocity push downhill; scale by amount we're moving
	vec2 norm_affect = clamp(u_terrain_res * vellen, vec2(1.0), vec2(50.0));
	vel -= (terrain_norm / norm_affect);
	vel *= 0.9;
	
	//normalize
	terrain_norm = normalize(terrain_norm);
	vec2 nvel = normalize(vel);

	//integrate
	float step_size = 1.0 / max(abs(nvel.x), abs(nvel.y));
	pos += (nvel * step_size) / u_terrain_res;
	//collide - bounce off walls
	const float bounce_amount = 1.0;
	vec2 min_vel_push = vec2(1.0) / u_terrain_res;
	if (pos.x < 0.0) {
		vel.x = max(min_vel_push.x, abs(vel.x)) * bounce_amount;
		pos.x = 0.0;
	} else if (pos.x > 1.0) {
		vel.x = max(min_vel_push.x, abs(vel.x)) * -bounce_amount;
		pos.x = 1.0;
	}
	if (pos.y < 0.0) {
		vel.y = max(min_vel_push.y, abs(vel.y)) * bounce_amount;
		pos.y = 0.0;
	} else if (pos.y > 1.0) {
		vel.y = max(min_vel_push.y, abs(vel.y)) * -bounce_amount;
		pos.y = 1.0;
	}

	//evaporate linear
	volume.x -= 1.0 / u_evap_iters;

	//displace volume based on speed and sediment capacity
	//get the maximum possible amount to subtract - half the amount of soil in the hill we've just come down
	float terrain_current = Texel(u_terrain, pos).r;
	float max_dissolve_now = (terrain_previous - terrain_current) * 0.5;

	//amount terrain normal "disagrees" with velocity
	float turb = clamp(
		(1.0 - dot(nvel, terrain_norm)) * 0.5,
		0.0, 1.0
	);

	//dissolve in
	float dissolve_amount = clamp(
		vellen * u_dissolve_rate,
		0.0, max_dissolve_now
	) * turb;
	volume.y += dissolve_amount;

	//sediment out
	float max_dissolved = max(
		carry_capacity(volume.x, vellen),
		volume.y - u_sediment_rate
	);
	if (volume.y > max_dissolved) {
		volume.y = max_dissolved;
	}

	//writeout MRT
	love_Canvases[0] = vec4(pos, 0.0, 1.0);
	love_Canvases[1] = vec4(vel, 0.0, 1.0);
	love_Canvases[2] = vec4(volume, 0.0, 1.0);
}
#endif
]])

--transfer sediment using the droplet textures
transfer_shader = lg.newShader([[
uniform Image u_old_pos;
uniform Image u_new_pos;

uniform Image u_old_volume;
uniform Image u_new_volume;

varying float v_sed_dif;

//hard cap
const float max_change = 0.1;

#ifdef VERTEX

attribute vec2 a_uv;
vec4 position(mat4 _t, vec4 _p) {
	float sed_pre = Texel(u_old_volume, a_uv).y;
	float sed_cur = Texel(u_new_volume, a_uv).y;
	float sed_dif = sed_pre - sed_cur;

	v_sed_dif = sed_dif;

	vec2 pos = Texel(u_old_pos, a_uv).xy;
	return vec4(pos * 2.0 - vec2(1.0), 0.0, 1.0);
}
#endif
#ifdef PIXEL
void effect() {
	float dif = clamp(v_sed_dif, -max_change, max_change);
	love_PixelColor = vec4(dif, 0.0, 0.0, 1.0);
}
#endif
]])

flow_shader = lg.newShader([[
uniform Image u_old_pos;
uniform float amount;

#ifdef VERTEX

attribute vec2 a_uv;
vec4 position(mat4 _t, vec4 _p) {
	vec2 pos = Texel(u_old_pos, a_uv).xy;
	return vec4(pos * 2.0 - vec2(1.0), 0.0, 1.0);
}
#endif
#ifdef PIXEL
void effect() {
	love_PixelColor = vec4(amount, 0.0, 0.0, 1.0);
}
#endif
]])

--a shader for drawing the terrain
terrain_shader = lg.newShader([[
uniform Image terrain;
uniform Image sediment;
uniform Image flow;
uniform vec2 terrain_res;

uniform vec3 scale;
uniform float u_rotation;

uniform vec3 u_low_col;
uniform vec3 u_high_col;
uniform vec3 u_sediment_col;
uniform vec3 u_flow_col;
uniform vec3 u_cliff_col;


varying vec2 v_uv;
#ifdef VERTEX
vec2 rotate(vec2 v, float t) {
	float c = cos(t);
	float s = sin(t);
	return mat2(c, s, -s, c) * v;
}
attribute vec2 a_uv;
vec4 position(mat4 t, vec4 p) {

	v_uv = a_uv;

	float h = Texel(terrain, a_uv).r;
	p = vec4(
		a_uv,
		(1.0 - h),
		1.0
	);
	p.xy -= vec2(0.5);
	p.xy = rotate(p.xy, u_rotation);

	p.xyz *= scale;

	p.yz = rotate(p.yz, -1.0);
	p.z *= -0.001;
	return t * p;
}
#endif
#ifdef PIXEL
]]..norm_src..[[
void effect() {
	vec4 t = vec4(1.0);
	//
	float height = Texel(terrain, v_uv).r;
	vec2 norm = norm(terrain, terrain_res, v_uv);

	//generate planar colouring
	float sf = clamp(
		Texel(sediment, v_uv).r * 5.0,
		0.0, 1.0
	);
	float ff = clamp(
		Texel(flow, v_uv).r * 5.0 - 0.2,
		0.0, 1.0
	);
	float hf = clamp(
		height * 2.0 - 1.0,
		0.0, 1.0
	);
	float cf = clamp(
		length(norm) * 30.0 - 0.01,
		0.0, 1.0
	);
	t.rgb = mix(
		mix(
			mix(
				mix(
					u_low_col,
					u_high_col,
					hf
				),
				u_sediment_col,
				sf
			),
			u_flow_col,
			ff
		),
		u_cliff_col,
		cf
	);

	//figure out light

	vec3 light_direction = normalize(vec3(1.0));

	vec3 norm_3d = vec3(
		norm,
		0.1
	);
	float l = 0.25 + 0.75 * clamp(
		dot(
			normalize(norm_3d),
			light_direction
		), 0.0, 1.0
	);
	//apply light
	t.rgb *= vec3(l);
	love_PixelColor = t;
}
#endif
]])

