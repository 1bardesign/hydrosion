--[[
	"Hydrosion"

	Simplified hydraulic erosion on the gpu in love
]]

--shorthand
lg = love.graphics

--no conf
love.window.setMode(0, 0, {
	fullscreen = "desktop"
})

require("util")
require("batteries"):export()

-------------------------------------------------------------------------------
--terrain generation - dumb fractal noise
function gen_terrain(res, pixel_per_km, seed)
	local t_id = love.image.newImageData(res, res, "r32f")
	
	--build random parameters for this seed
	local _r = love.math.newRandomGenerator(seed)
	
	local sox = _r:random(-100, 100)
	local soy = _r:random(-100, 100)

	local oox = _r:random(-1000, 1000) / 31
	local ooy = _r:random(-1000, 1000) / 31

	local n = function(x, y, scale)
		return (
			love.math.noise(
				x * scale + sox,
				y * scale + soy
			) * 2 - 1
		)
	end
	local fn = function(x, y, scale, octaves)
		local s = scale
		local t = 0.5
		local c = 0
		for i = 1, octaves do
			a = 1 / (i * 1.2)
			local o = n(x, y, s)
			if i % 2 == 1 then
				o = math.abs(o)
			end
			t = t + o * a
			c = c + a
			--purturb
			local ox, oy = x, y
			x = oy + oox
			y = ox + ooy
			s = s * 1.73
		end
		return t / c
	end
	t_id:mapPixel(function(x, y)
		return fn(x, y, 0.001 * res / pixel_per_km, 8) + _r:random() * 0.02
	end)
	return image_to_canvas(lg.newImage(t_id))
end

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
local _integrate_shader = lg.newShader([[
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
local _transfer_shader = lg.newShader([[
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

local _flow_shader = lg.newShader([[
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

-------------------------------------------------------------------------------
-- create an erosion sim object
function erosion(arg)
	local res = arg.res or 32
	local tw, th = arg.terrain:getDimensions()
	local r = {
		--erosion params
		dissolve_rate = arg.dissolve_rate or 0.1,
		sediment_rate = arg.sediment_rate or arg.dissolve_rate or 0.1,
		max_dissolved = arg.max_dissolved or 0.1,
		--sizes
		res = res,
		tw = tw,
		th = th,
		initial_vel = arg.initial_vel or 0.1,
		--
		terrain = arg.terrain,
		terrain_res = {tw, th},
		sediment = lg.newCanvas(tw, th, {format = "r32f"}),
		flow = lg.newCanvas(tw, th, {format = "r32f"}),
		--
		mesh = uv_mesh(res, res, "points"),
		--
		new_texture_set = function(self)
			local r = {
				pos = random_xy_01(self.res),
				vel = random_xy_signed(self.res, self.initial_vel / res),
				volume = rg_square(self.res),
			}
			r.volume:setWrap("clamp", "clamp")
			r.volume:renderTo(function()
				lg.clear(1, 0, 0, 1)
			end)
			r.canvas_setup = {
				r.pos,
				r.vel,
				r.volume,
			}
			return r
		end,
		do_pass = function(self, iters)
			--fade old flow layer
			local flow_fade_amount = 0.02
			local flow_add_amount = 0.04
			lg.push("all")
			lg.setCanvas(self.flow)
			lg.setShader()
			lg.setColor(0,0,0,flow_fade_amount)
			lg.rectangle("fill", 0, 0, self.tw, self.th)
			lg.setColor(1,1,1,1)
			lg.pop()
			--render out iteration
			lg.push("all")
			--new positions
			self.old = self.current
			self.current = self:new_texture_set()
			for i = 1, iters do
				--double buffer
				self.current, self.old = self.old, self.current

				--integrate points
				lg.setBlendMode("replace")
				lg.setShader(_integrate_shader)
				_integrate_shader:send("u_terrain", self.terrain)
				_integrate_shader:send("u_terrain_res", self.terrain_res)
				_integrate_shader:send("u_vel", self.old.vel)
				_integrate_shader:send("u_pos", self.old.pos)
				_integrate_shader:send("u_volume", self.old.volume)
				_integrate_shader:send("u_evap_iters", iters)
				_integrate_shader:send("u_dissolve_rate", self.dissolve_rate)
				_integrate_shader:send("u_sediment_rate", self.sediment_rate)
				_integrate_shader:send("u_max_carry_frac", self.max_dissolved)
				lg.setCanvas(self.current.canvas_setup)
				lg.draw(self.old.vel)

				--transfer
				lg.setBlendMode("add")
				lg.setShader(_transfer_shader)
				_transfer_shader:send("u_old_pos", self.old.pos)
				_transfer_shader:send("u_old_volume", self.old.volume)
				_transfer_shader:send("u_new_volume", self.current.volume)
				--transfer actual volume
				lg.setCanvas(self.terrain)
				lg.draw(self.mesh)
				--transfer to sediment
				lg.setCanvas(self.sediment)
				lg.draw(self.mesh)
				--update sedimentation amount
				lg.setCanvas(self.flow)
				lg.setShader(_flow_shader)
				_flow_shader:send("u_old_pos", self.old.pos);
				_flow_shader:send("amount", flow_add_amount / iters);
				lg.draw(self.mesh)
			end
			lg.pop()
		end,
	}
	r.current = r:new_texture_set()
	r.old = r:new_texture_set()
	return r
end

-------------------------------------------------------------------------------
--our terrain

local terrain_res = 512
local terrain_scale = 512
local terrain = gen_terrain(terrain_res, terrain_scale, love.math.random(1, 100000))
local tw, th = terrain:getDimensions()

-------------------------------------------------------------------------------
--visualisation stuff

--the mesh for drawing the terrain with
local tmesh = uv_mesh(tw, th, "points", true)
local indices = {}
for y = 0, tw - 1 do
	for x = 0, th - 1 do
		local ox = 1
		local oy = tw + 1
		local idx = x * ox + y * oy + 1
		table.insert(indices, idx)
		table.insert(indices, idx + ox)
		table.insert(indices, idx + ox + oy)

		table.insert(indices, idx)
		table.insert(indices, idx + ox + oy)
		table.insert(indices, idx + oy)
	end
end
tmesh:setVertexMap(indices)
tmesh:setDrawMode("triangles")

--a shader for drawing it
--just dot lighting with a static source and ortho projection
local tshad = lg.newShader([[
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

--any more local storage
local sim

local v_rotation = 0.0

--boot and reboot
function love.load()
	terrain = gen_terrain(terrain_res, terrain_scale, love.math.random(1, 100000))
	tw, th = terrain:getDimensions()

	sim = erosion({
		terrain = terrain,
		res = 64,
		initial_vel = 10.0,
		dissolve_rate = 0.05,
		sediment_rate = 0.05,
		max_dissolved = 0.075,
	})

	tshad:send("terrain", terrain)
	tshad:send("terrain_res", {tw, th})
	tshad:send("scale", {tw * 2.5, th * 2.5, 256})
	tshad:send("u_rotation", v_rotation)
	tshad:send("sediment", sim.sediment)
	tshad:send("flow", sim.flow)
	tshad:send("u_low_col",      {0.4, 0.7, 0.2})
	tshad:send("u_high_col",     {0.9, 0.9, 1.0})
	tshad:send("u_sediment_col", {0.8, 0.7, 0.4})
	tshad:send("u_flow_col",     {0.5, 0.6, 0.8})
	tshad:send("u_cliff_col",    {0.4, 0.2, 0.2})
end

--simulate if space held down
function love.update(dt)
	if love.keyboard.isDown("space") then
		sim:do_pass(800)
	end

	local spin_speed = math.pi * dt
	if love.keyboard.isDown("left") then
		v_rotation = v_rotation + spin_speed
	end
	if love.keyboard.isDown("right") then
		v_rotation = v_rotation - spin_speed
	end
end

--draw everything; debug and terrain
function love.draw()
	lg.push()
	for i,v in ipairs{
		sim.terrain,
		sim.sediment,
		sim.flow,
		sim.current.pos,
		sim.current.vel,
		sim.current.volume,
	} do
		lg.draw(v)
		lg.translate(v:getWidth() + 1, 0)
	end
	lg.pop()
	
	--draw mesh
	lg.push("all")
	lg.translate(lg.getWidth() * 0.5, lg.getHeight() * 0.5)

	lg.setDepthMode("less", true)
	lg.setCanvas({depth=true})
	lg.setShader(tshad)
	tshad:send("u_rotation", v_rotation)
	lg.draw(tmesh)

	lg.pop()
end

--keyboard interaction
function love.keypressed(k)
	local ctrl = love.keyboard.isDown("lctrl")
	if ctrl then
		if k == "r" then
			love.event.quit("restart")
		elseif k == "q" then
			love.event.quit()
		elseif k == "s" then
			--save out images
			for _, v in ipairs {
				{"i_height", sim.terrain},
				{"i_sediment", sim.sediment},
				{"i_flow", sim.flow},
			} do
				local n, t = table.unpack2(v)
				n = ("%s-%d.png"):format(n, os.time())
				local f = io.open(n, "wb")
				if f then
					local id = love.image.newImageData(t:getDimensions())
					id:paste(t:newImageData(), 0, 0)
					local s = id:encode("png"):getString()
					f:write(s)
					f:close()
				end
			end
		end
	else
		if k == "r" then
			love.load()
		end
	end
end
