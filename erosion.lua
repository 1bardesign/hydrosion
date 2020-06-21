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

		vel_evap = arg.vel_evap or 0.1,
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
				integrate_shader:send("u_dissolve_rate", self.dissolve_rate)
				integrate_shader:send("u_sediment_rate", self.sediment_rate)
				integrate_shader:send("u_max_carry_frac", self.max_dissolved)
				integrate_shader:send("u_evap_iters", iters)
				integrate_shader:send("u_vel_evap_factor", self.vel_evap)
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
