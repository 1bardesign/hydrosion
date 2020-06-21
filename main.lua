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
require("gen_terrain")
require("erosion")

-------------------------------------------------------------------------------
--our terrain

local terrain_res = 800
local terrain_scale = 512
local terrain = gen_terrain(terrain_res, terrain_scale, love.math.random(1, 100000))
local tw, th = terrain:getDimensions()

--todo: collision mode dependent wrapping
-- terrain:setWrap("repeat")

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
local v_zoom = 1.0

function load_terrain(id)
	terrain = image_to_canvas(lg.newImage(id), "r32f")
	tw, th = terrain:getDimensions()

	sim_iters = 500

	sim = erosion({
		terrain = terrain,
		res = 64,
		initial_vel = 1.0,
		dissolve_rate = 0.025,
		sediment_rate = 0.05,
		max_dissolved = 0.01,
		vel_evap = 0.25,
	})

	terrain_shader:send("terrain", terrain)
	terrain_shader:send("terrain_res", {tw, th})
	terrain_shader:send("u_scale", {tw * 2.5 * v_zoom, th * 2.5 * v_zoom, 256 * v_zoom})
	terrain_shader:send("u_rotation", v_rotation)
	terrain_shader:send("sediment", sim.sediment)
	terrain_shader:send("flow", sim.flow)
	terrain_shader:send("u_low_col",      {0.4, 0.7, 0.2})
	terrain_shader:send("u_high_col",     {0.9, 0.9, 1.0})
	terrain_shader:send("u_sediment_col", {0.8, 0.7, 0.4})
	terrain_shader:send("u_flow_col",     {0.5, 0.6, 0.8})
	terrain_shader:send("u_cliff_col",    {0.4, 0.2, 0.2})
end

--boot and reboot
function love.load()
	load_terrain(gen_terrain(terrain_res, terrain_scale, love.math.random(1, 100000)))
end

--simulate if space held down
function love.update(dt)
	if love.keyboard.isDown("space") then
		sim:do_pass(sim_iters)
	end

	local spin_speed = math.pi * 0.25 * dt
	if love.keyboard.isDown("left") then
		v_rotation = v_rotation + spin_speed
	end
	if love.keyboard.isDown("right") then
		v_rotation = v_rotation - spin_speed
	end

	local zoom_speed = 1.5
	if love.keyboard.isDown("up") then
		v_zoom = math.lerp(v_zoom, v_zoom * zoom_speed, dt)
	end
	if love.keyboard.isDown("down") then
		v_zoom = math.lerp(v_zoom, v_zoom / zoom_speed, dt)
	end
	local max_zoom = 5
	v_zoom = math.clamp(v_zoom, 1 / max_zoom, max_zoom)
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
	terrain_shader:send("u_scale", {tw * 2.5 * v_zoom, th * 2.5 * v_zoom, 256 * v_zoom})
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
					local tid = t:newImageData()
					local w, h = t:getDimensions()
					local id = love.image.newImageData(w, h, "rgba16")
					id:paste(tid, 0, 0)
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

function love.filedropped(f)
	f:open("r")
	local bd = f:read("data")
	local id = love.image.newImageData(bd)
	load_terrain(id)
end
