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

require("batteries"):export()
require("util")
require("shaders")

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
				lg.setShader(integrate_shader)
				integrate_shader:send("u_terrain", self.terrain)
				integrate_shader:send("u_terrain_res", self.terrain_res)
				integrate_shader:send("u_vel", self.old.vel)
				integrate_shader:send("u_pos", self.old.pos)
				integrate_shader:send("u_volume", self.old.volume)
				integrate_shader:send("u_evap_iters", iters)
				integrate_shader:send("u_dissolve_rate", self.dissolve_rate)
				integrate_shader:send("u_sediment_rate", self.sediment_rate)
				integrate_shader:send("u_max_carry_frac", self.max_dissolved)
				lg.setCanvas(self.current.canvas_setup)
				lg.draw(self.old.vel)

				--transfer
				lg.setBlendMode("add")
				lg.setShader(transfer_shader)
				transfer_shader:send("u_old_pos", self.old.pos)
				transfer_shader:send("u_old_volume", self.old.volume)
				transfer_shader:send("u_new_volume", self.current.volume)
				--transfer actual volume
				lg.setCanvas(self.terrain)
				lg.draw(self.mesh)
				--transfer to sediment
				lg.setCanvas(self.sediment)
				lg.draw(self.mesh)
				--update sedimentation amount
				lg.setCanvas(self.flow)
				lg.setShader(flow_shader)
				flow_shader:send("u_old_pos", self.old.pos);
				flow_shader:send("amount", flow_add_amount / iters);
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

	terrain_shader:send("terrain", terrain)
	terrain_shader:send("terrain_res", {tw, th})
	terrain_shader:send("scale", {tw * 2.5, th * 2.5, 256})
	terrain_shader:send("u_rotation", v_rotation)
	terrain_shader:send("sediment", sim.sediment)
	terrain_shader:send("flow", sim.flow)
	terrain_shader:send("u_low_col",      {0.4, 0.7, 0.2})
	terrain_shader:send("u_high_col",     {0.9, 0.9, 1.0})
	terrain_shader:send("u_sediment_col", {0.8, 0.7, 0.4})
	terrain_shader:send("u_flow_col",     {0.5, 0.6, 0.8})
	terrain_shader:send("u_cliff_col",    {0.4, 0.2, 0.2})
end

--simulate if space held down
function love.update(dt)
	if love.keyboard.isDown("space") then
		sim:do_pass(800)
	end

	local spin_speed = math.pi * 0.25 * dt
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
	lg.setShader(terrain_shader)
	terrain_shader:send("u_rotation", v_rotation)
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
