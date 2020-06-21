-------------------------------------------------------------------------------
--various helper functions

--convert an image to a canvas so we can render to it
function image_to_canvas(i, format)
	local c = lg.newCanvas(i:getWidth(), i:getHeight(), {format = format or i:getFormat()})
	lg.setCanvas(c)
	lg.draw(i)
	lg.setCanvas()
	return c
end

--generate a rg32f square texture
function rg_square(res)
	return lg.newCanvas(res, res, {format = "rg32f"})
end

--generate a 0-1 random xy texture, useful for positions on a unit square perhaps!
function random_xy_01(res)
	local id = love.image.newImageData(res, res, "rg32f")
	id:mapPixel(function()
		return love.math.random(), love.math.random(), 0, 1
	end)
	return image_to_canvas(lg.newImage(id))
end

--generate a random xy signed texture, useful for starting velocities
function random_xy_signed(res, scale)
	local c = rg_square(res)
	lg.push("all")
	lg.setCanvas(c)
	for i,v in ipairs {
		"add", "subtract"
	} do
		lg.setBlendMode(v)
		for y = 0, res - 1 do
			for x = 0, res - 1 do
				lg.setColor(love.math.random() * scale, love.math.random() * scale, 0, 1)
				lg.points(x, y)
			end
		end
	end
	lg.pop()
	return c
end

--generate a mesh with just uv verts, covering an entire texture
function uv_mesh(w, h, mode, extra)
	--mesh for drawing points into terrain
	local verts = {}
	local o = (extra and 0 or 1)
	for y = 0, h - o do
		for x = 0, w - o do
			table.insert(verts, {
				(x + 0.5) / w,
				(y + 0.5) / h
			})
		end
	end
	local mesh = lg.newMesh({
		{"a_uv", "float", 2},
		{"VertexPosition", "float", 2}, --unused but required
	}, (w - o + 1) * (h - o + 1), mode, "static")
	mesh:setVertices(verts)
	return mesh
end
