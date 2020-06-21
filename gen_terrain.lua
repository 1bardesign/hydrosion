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
		
		x = x + sox
		y = y + soy

		local s = scale
		local t = 0
		local c = 0
		local octave_falloff = 0.7
		local octave_scale = 1.5
		local a = 1
		for i = 1, octaves do
			local o = n(x, y, s)
			if i % 2 == 1 then
				o = math.abs(o) * 2 - 1
			end

			t = t + o * a
			c = c + a

			x = x + oox
			y = y + oox

			s = s * octave_scale
			a = a * octave_falloff
		end
		return 0.5 + (t / c) * 0.75
	end
	--perlin mountains
	-- t_id:mapPixel(function(x, y)
	-- 	return fn(x, y, 0.001 * res / pixel_per_km, 16)
	-- end)

	--well
	t_id:mapPixel(function(x, y)
		local n = fn(x, y, 0.001 * res / pixel_per_km, 16)
		
		local xf = math.smoothstep(x / res)
		local yf = math.smoothstep(y / res)

		local dx = (xf - 0.5)
		local dy = (yf - 0.5)

		local d = math.sqrt(dx * dx + dy * dy) * 1.5

		return math.lerp(
			math.lerp(0.7, 0.8, n),
			math.lerp(
				math.lerp(0.0, 1.0, n),
				math.lerp(0.3, 0.4, n),
				math.clamp01(1 - d * 2)
			),
			math.clamp01(1 - d)
		)
	end)

	return t_id
end
