--!strict
--!native
--!optimize 2

-- <// METAMATRIX CORE //                   |                // CREATED BY DEATH_HUNTER1227 //>

local Matrix = {}
Matrix.__index = Matrix

type TransposeCache = {
	rows: number,
	columns: number,
	source: buffer,
	data: buffer,
	id: number,
}

type MatrixData = {
	Rows: number,
	Columns: number,
	Data: buffer,
	Parallel: boolean,
	_transposedCache: TransposeCache?,
	_dirty: boolean?,
}

export type Matrix = typeof(setmetatable({} :: MatrixData, Matrix))

local WORKER_COUNT = 1
local activeJobs = 0
local runService = game:GetService("RunService")
local workerParent: Instance
if runService:IsServer() then
	workerParent = game:GetService("ServerScriptService")
else
	local player = assert(game:GetService("Players").LocalPlayer, "Matrix requires a local player on the client")
	workerParent = player:WaitForChild("PlayerScripts")
end
local workerFolder = Instance.new("Folder")
workerFolder.Name = "MatrixWorkers"
workerFolder.Parent = workerParent
local templateActor = script.Parent:WaitForChild("MatrixActorTemplate")
assert(templateActor:IsA("Actor"), "MatrixActorTemplate must be an Actor")
local workerPool: {Actor} = {}

local replyEvent = Instance.new("BindableEvent")
local workerCaches: {[number]: number?} = {}
local nextCacheId = 0
local nextJobId = 0

local readf32 = buffer.readf32
local writef32 = buffer.writef32


--[[
	Changes the total worker count. More workers = higher speeds, but higher memory usage. One worker occupies one core. 
	@param target The target amount of workers. Recommended: <b> 8 </b>
]]
function Matrix.SetWorkerCount(target: number): ()
	if script:GetActor() then
		return
	end
	
	if type(target) ~= "number" then
		error("SetWorkerCount: target must be a number, got " .. type(target))
	end
	assert(target >= 1 and target % 1 == 0, "Worker count must be a positive integer.")
	assert(target <= 256, "Worker count cannot exceed 256.")
	assert(activeJobs == 0, "Cannot change worker count while matrix multiplication is running.")
	local previousCount = #workerPool
	local spawnedNew = false
	if #workerPool < target then
		for i = #workerPool + 1, target do 
			local clone = templateActor:Clone()
			clone.Name = "MatrixWorker_" .. i
			clone.Parent = workerFolder
			workerPool[i] = clone
		end 
		spawnedNew = true

	elseif #workerPool > target then
		for i = #workerPool, target + 1, -1 do 
			workerPool[i]:Destroy()
			table.remove(workerPool, i)
			workerCaches[i] = nil
		end 
	end

	if spawnedNew then
		local deadline = os.clock() + 10
		for i = previousCount + 1, target do
			while not workerPool[i]:GetAttribute("Ready") do
				if os.clock() >= deadline then
					for j = #workerPool, previousCount + 1, -1 do
						workerPool[j]:Destroy()
						table.remove(workerPool, j)
					end
					error("Matrix workers failed to start within 10 seconds.")
				end
				task.wait()
			end
		end
	end
	WORKER_COUNT = target
end

Matrix.SetWorkerCount(1)

--[[
	Creates a new matrix object.
	@param rows The amount of rows the matrix should contain.
	@param columns The amount of columns the matrix should contain.
	@param parallel Whether on not the matrix should run in parallel.
	@param alloc Whethee or not the matrix should auto-allocate with numbers.
	@param startVal The starting value allocation will begin at (located in row 1, column 1).
	@param stepOffset The amount each number should change by.
]]
function Matrix.new(rows: number, columns: number, parallel: boolean?, alloc: boolean?, startVal: number?, stepOffset: number?): Matrix
	if type(rows) ~= "number" or type(columns) ~= "number" then
		error("Matrix.new: rows and columns must be numbers")
	end
	assert(rows > 0 and columns > 0, "Rows and columns must be greater than 0.")
	assert(rows % 1 == 0 and columns % 1 == 0, "Rows and columns must be integers.")

	local total_bytes  = rows * columns * 4

	local d_buf = buffer.create(total_bytes)
	local step = 1
	local start = 0
	local last_byte_offset = total_bytes - 4

	if alloc then
		if stepOffset then 
			if type(stepOffset) ~= "number" then
				error("Matrix.new: stepOffset must be a number, got " .. type(stepOffset))
			end
			step = stepOffset 
		end
		if startVal then 
			if type(startVal) ~= "number" then
				error("Matrix.new: startVal must be a number, got " .. type(startVal))
			end
			start = startVal 
		end

		local current_val = start 
		for byte_offset = 0, last_byte_offset, 4 do
		writef32(d_buf, byte_offset, current_val)
		current_val += step 
	end
	end

	return setmetatable({
		Rows = rows,
		Columns = columns,
		Data = d_buf,
		Parallel = parallel or false,
	}, Matrix)
end

--[[
	Creates an identity matrix.
	@param size_n The amount of rows and columns the matrix should have.
	@param parallel Whether or not the matrix should deploy workers during multiplication.
]]
function Matrix.CreateIdentity(size_n: number, parallel: boolean?): Matrix
	if type(size_n) ~= "number" then
		error("CreateIdentity: size_n must be a number, got " .. type(size_n))
	end
	assert(size_n > 0 and size_n % 1 == 0, "Size must be a positive integer.")
	
	if parallel ~= nil and type(parallel) ~= "boolean" then
		error("CreateIdentity: parallel must be boolean, got " .. type(parallel))
	end

	local res_buffer = buffer.create(size_n * size_n * 4)

	for i = 0, size_n - 1 do 
		writef32(res_buffer, (i * size_n + i) * 4, 1.0)
	end 

	return setmetatable({
		Rows = size_n,
		Columns = size_n,
		Data = res_buffer,
		Parallel = parallel or false
	}, Matrix)
end

--[[
	Generates a random matrix.
	@param rows The amount of rows the matrix should have.
	@param columns The amount of columns the matrix should have.
	@param min_val The min value which could exist within an element.
	@param max_val The max value which could exist within an element.
	@param parallel Whether or not the matrix should deploy workers during multiplication.
]]
function Matrix.GenerateRandom(rows: number, columns: number, min_val: number?, max_val: number?, parallel: boolean?): Matrix
	if type(rows) ~= "number" or type(columns) ~= "number" then
		error("GenerateRandom: rows and columns must be numbers")
	end
	assert(rows > 0 and columns > 0, "Rows and columns must be greater than 0.")
	assert(rows % 1 == 0 and columns % 1 == 0, "Rows and columns must be integers.")

	local min_v = min_val or -1.0
	local max_v = max_val or 1.0
	
	if min_val ~= nil and type(min_val) ~= "number" then
		error("GenerateRandom: min_val must be a number, got " .. type(min_val))
	end
	if max_val ~= nil and type(max_val) ~= "number" then
		error("GenerateRandom: max_val must be a number, got " .. type(max_val))
	end
	if parallel ~= nil and type(parallel) ~= "boolean" then
		error("GenerateRandom: parallel must be boolean, got " .. type(parallel))
	end
	
	assert(min_v < max_v, "min_val must be less than max_val")
	
	local range = max_v - min_v
	if range <= 0 then
		error("GenerateRandom: invalid range between min and max values")
	end
	
	local total_bytes = rows * columns * 4 
	local res_buffer = buffer.create(total_bytes)
	
	for byte_offset = 0, total_bytes - 4, 4 do 
		writef32(res_buffer, byte_offset, min_v + (math.random() * range))
	end 

	return setmetatable({
		Rows = rows,
		Columns = columns,
		Data = res_buffer,
		Parallel = parallel or false
	}, Matrix)
end

-- FUNCS
--[[
	Changes a matrix to run in parallel.
	@param x The value to determine if matrices will be multiplied in parallel.
]]
function Matrix.MulParallel(self: Matrix, x: boolean): ()
	self.Parallel = x
end

--[[
	Invalidates the cached transpose after direct changes to Data.
]]
function Matrix.MarkDirty(self: Matrix): ()
	self._dirty = true
end

--[[
	Returns the current element at the specified location.
	@param currentRow The row to fetch the element from.
	@param currentColumn The column to fetch the element from.
]]
function Matrix.Get(self: Matrix, currentRow: number, currentColumn: number): number?
	if type(currentRow) ~= "number" or type(currentColumn) ~= "number" then
		error("Get: row and column must be numbers")
	end
	if currentRow >= 1 and currentRow <= self.Rows and currentColumn >= 1 and currentColumn <= self.Columns then
		local byte_offset = (((currentRow - 1) * self.Columns + (currentColumn - 1)) * 4)
		return readf32(self.Data, byte_offset)
	end
	return nil
end

--[[
	Sets the current element at the specified location to the specified value.
	@param currentRow The row to set the element to.
	@param currentColumn The column to set the element to.
	@param newVal The value the element should be changed to.
]]
function Matrix.Set(self: Matrix, currentRow: number, currentColumn: number, newVal: number): ()
	if type(currentRow) ~= "number" or type(currentColumn) ~= "number" or type(newVal) ~= "number" then
		error("Set: row, column, and value must be numbers")
	end
	if currentRow >= 1 and currentRow <= self.Rows and currentColumn >= 1 and currentColumn <= self.Columns then
		local byte_offset = (((currentRow - 1) * self.Columns + (currentColumn - 1)) * 4)
		writef32(self.Data, byte_offset, newVal)
		self._dirty = true
	end
end

--[[
	Returns the cloned variant of a matrix.
]]
function Matrix.Clone(self: Matrix): Matrix
	if self.Data == nil or self.Rows == nil or self.Columns == nil then
		error("Clone: invalid matrix structure")
	end
	local total_bytes = buffer.len(self.Data)

	local new_buffer = buffer.create(total_bytes)
	buffer.copy(new_buffer, 0, self.Data, 0, total_bytes)

		return setmetatable({
		Rows = self.Rows,
		Columns = self.Columns,
		Data = new_buffer,
		Parallel = self.Parallel
	}, Matrix)
end

--[[
	Sets all elements in the matrix to 0. Does not return a matrix.
]]
function Matrix.Zero(self: Matrix): ()
	if self.Data == nil then
		error("Zero: invalid matrix structure")
	end
	buffer.fill(self.Data, 0, 0, buffer.len(self.Data))
	self._dirty = true
end

--[[
	Flips the rows and columns of a matrix. Returns a new matrix.
]]
function Matrix.Transpose(self: Matrix): Matrix
	if self.Data == nil or self.Rows == nil or self.Columns == nil then
		error("Transpose: invalid matrix structure")
	end
	local tot_rows = self.Rows
	local tot_cols = self.Columns
	local src_buffer = self.Data
	local transposed_buffer = buffer.create(buffer.len(src_buffer))
	local readu32 = buffer.readu32
	local writeu32 = buffer.writeu32
	local row_bytes = tot_cols * 4
	local TILE = 16
	for r_block = 0, tot_rows - 1, TILE do
		local r_end = math.min(r_block + TILE, tot_rows)
		for c_block = 0, tot_cols - 1, TILE do
			local c_end = math.min(c_block + TILE - 1, tot_cols - 1)
			local r = r_block
			while r + 3 < r_end do
				local src_row_base = r * row_bytes
				for c = c_block, c_end do
					local src_offset = src_row_base + c * 4
					local dst_offset = (c * tot_rows + r) * 4
					writeu32(transposed_buffer, dst_offset, readu32(src_buffer, src_offset))
					writeu32(transposed_buffer, dst_offset + 4, readu32(src_buffer, src_offset + row_bytes))
					writeu32(transposed_buffer, dst_offset + 8, readu32(src_buffer, src_offset + 2 * row_bytes))
					writeu32(transposed_buffer, dst_offset + 12, readu32(src_buffer, src_offset + 3 * row_bytes))
				end
				r += 4
			end
			while r < r_end do
				for c = c_block, c_end do
					writeu32(transposed_buffer, (c * tot_rows + r) * 4, readu32(src_buffer, (r * tot_cols + c) * 4))
				end
				r += 1
			end
		end
	end

	return setmetatable({
		Rows = tot_cols,
		Columns = tot_rows,
		Data = transposed_buffer,
		Parallel = self.Parallel
	}, Matrix)
end


function Matrix.__tostring(mat: Matrix): string
	if not mat or mat.Rows == nil or mat.Columns == nil or mat.Data == nil then
		return "Invalid Matrix"
	end
	local rows = mat.Rows
	local cols = mat.Columns
	local data = mat.Data
	local output_lines = table.create(rows + 2)
	output_lines[1] = string.format("Matrix (%dx%d):", rows, cols)

	for r_i = 0, rows - 1 do 
		local row_strings = table.create(cols)
		local row_byte_start = r_i * cols * 4
		for c_j  = 0, cols - 1 do 
			local cur_float = readf32(data, row_byte_start + (c_j * 4))

			row_strings[c_j + 1] = string.format("%.2f", cur_float)
		end
		output_lines[r_i + 2] = table.concat(row_strings, "\t")
	end 
	return table.concat(output_lines, "\n")
end

--[[
	Calculates the Hadamard product between 2 matrices. Returns a new matrix.
	@param other_mat The other matrix to be multiplied.
]]
function Matrix.Hadamard(self: Matrix, other_mat: Matrix): Matrix
	if not other_mat then
		error("Hadamard: operand cannot be nil")
	end
	if other_mat.Data == nil or other_mat.Rows == nil or other_mat.Columns == nil then
		error("Hadamard: invalid matrix structure")
	end
	assert(self.Rows == other_mat.Rows and self.Columns == other_mat.Columns, "Dimensions must match for Hadamard product.")

	local buf_a = self.Data
	local buf_b = other_mat.Data
	local total_bytes = buffer.len(buf_a)

	local res_buffer = buffer.create(total_bytes)
	for byte_offset = 0, total_bytes - 4, 4 do 
		writef32(res_buffer, byte_offset, readf32(buf_a, byte_offset) * readf32(buf_b, byte_offset))
	end 

	return setmetatable({
		Rows = self.Rows,
		Columns = self.Columns,
		Data = res_buffer,
		Parallel = self.Parallel
	}, Matrix)
end

--[[
	Returns the determinant of the matrix.
]]
function Matrix.Determinant(self: Matrix): number
	if self.Data == nil or self.Rows == nil or self.Columns == nil then
		error("Determinant: invalid matrix structure")
	end
	assert(self.Rows == self.Columns, "Matrix must be a square for determinant.")
	local size_n = self.Rows
	
	if type(size_n) ~= "number" or size_n <= 0 then
		error("Determinant: invalid matrix dimensions")
	end
	
	local row_bytes = size_n * 4
	local total_bytes = size_n * row_bytes

	local work_buffer = buffer.create(total_bytes)
	buffer.copy(work_buffer, 0, self.Data, 0, total_bytes)
	local temp_row_buffer = buffer.create(row_bytes)

	local det_sign = 1.0

	for pivot_col = 0, size_n - 1 do
		local best_row = pivot_col
		local max_abs_val = math.abs(readf32(work_buffer, (pivot_col * size_n + pivot_col) * 4))

		for search_row = pivot_col + 1, size_n - 1 do 
			local val = math.abs(readf32(work_buffer, (search_row * size_n + pivot_col) * 4))
			if val > max_abs_val then 
				max_abs_val = val
				best_row = search_row
			end 
		end 

		if max_abs_val < 1e-7 then 
			return 0.0
		end 

		
		if best_row ~= pivot_col then 
			local offset_a = pivot_col * row_bytes
			local offset_b = best_row * row_bytes

			buffer.copy(temp_row_buffer, 0, work_buffer, offset_a, row_bytes)
			buffer.copy(work_buffer, offset_a, work_buffer, offset_b, row_bytes)
			buffer.copy(work_buffer, offset_b, temp_row_buffer, 0, row_bytes)

			det_sign = -det_sign
		end

		for targ_row = pivot_col + 1, size_n - 1 do
			local pivot_val = readf32(work_buffer, (pivot_col * size_n + pivot_col) * 4)
			if pivot_val == nil then
				error("Determinant: failed to read pivot value")
			end
			if math.abs(pivot_val) < 1e-10 then
				return 0.0
			end
			local targ_row_offset = targ_row * row_bytes
			local pivot_row_offset = pivot_col * row_bytes
			local factor = readf32(work_buffer, targ_row_offset + (pivot_col * 4)) / pivot_val

			if factor ~= 0.0 then
				local unroll_lim = row_bytes - (row_bytes % 16)
				local byte_step = pivot_col * 4
				
				while byte_step < unroll_lim do
					local i_targ = targ_row_offset + byte_step
					local i_pivot = pivot_row_offset + byte_step
					
					writef32(work_buffer, i_targ, readf32(work_buffer, i_targ) - factor * readf32(work_buffer, i_pivot))
					writef32(work_buffer, i_targ + 4, readf32(work_buffer, i_targ + 4) - factor * readf32(work_buffer, i_pivot + 4))
					writef32(work_buffer, i_targ + 8, readf32(work_buffer, i_targ + 8) - factor * readf32(work_buffer, i_pivot + 8))
					writef32(work_buffer, i_targ + 12, readf32(work_buffer, i_targ + 12) - factor * readf32(work_buffer, i_pivot + 12))
					
					byte_step += 16
				end
				
				while byte_step < row_bytes do
					local i_targ = targ_row_offset + byte_step
					local i_pivot = pivot_row_offset + byte_step
					writef32(work_buffer, i_targ, readf32(work_buffer, i_targ) - factor * readf32(work_buffer, i_pivot))
					byte_step += 4
				end
			end

		end
	end
	local det = det_sign
	for i = 0, size_n - 1 do
		det *= readf32(work_buffer, (i * size_n + i) * 4)
	end
	return det
end

--[[
	Returns the inverse of the matrix.
]]
function Matrix.Inverse(self: Matrix): Matrix
	if self.Data == nil or self.Rows == nil or self.Columns == nil then
		error("Inverse: invalid matrix structure")
	end
	assert(self.Rows == self.Columns, "Matrix must be a square to invert.")

	local size_n = self.Rows
	
	if type(size_n) ~= "number" or size_n <= 0 then
		error("Inverse: invalid matrix dimensions")
	end
	
	local row_bytes = size_n * 4
	local total_bytes = size_n * row_bytes

	local work_buffer = buffer.create(total_bytes)
	buffer.copy(work_buffer, 0, self.Data, 0, total_bytes)
	local inverse_buffer = buffer.create(total_bytes)

	for i = 0, size_n - 1 do
		writef32(inverse_buffer, (i * size_n + i) * 4, 1.0)
	end

	local temp_row_buffer = buffer.create(row_bytes)

	for pivot_col = 0, size_n - 1 do
		local best_row = pivot_col
		local max_abs_val = math.abs(readf32(work_buffer, (pivot_col * size_n + pivot_col) * 4))

		for search_row = pivot_col + 1, size_n - 1 do 
			local val = math.abs(readf32(work_buffer, (search_row * size_n + pivot_col) * 4))
			if val > max_abs_val then 
				max_abs_val = val
				best_row = search_row
			end 
		end 

		if max_abs_val < 1e-7 then 
			error("Matrix is singular and thus cannot be inverted.")
		end 

		if best_row ~= pivot_col then 
			local offset_a = pivot_col * row_bytes
			local offset_b = best_row * row_bytes

			buffer.copy(temp_row_buffer, 0, work_buffer, offset_a, row_bytes)
			buffer.copy(work_buffer, offset_a, work_buffer, offset_b, row_bytes)
			buffer.copy(work_buffer, offset_b, temp_row_buffer, 0, row_bytes)

			buffer.copy(temp_row_buffer, 0, inverse_buffer, offset_a, row_bytes)
			buffer.copy(inverse_buffer, offset_a, inverse_buffer, offset_b, row_bytes)
			buffer.copy(inverse_buffer, offset_b, temp_row_buffer, 0, row_bytes)

		end

		local pivot_row_offset = pivot_col * row_bytes
		local pivot_val = readf32(work_buffer, pivot_row_offset + (pivot_col * 4))
		if pivot_val == nil or pivot_val == 0 then
			error("Inverse: singular matrix - cannot invert")
		end
		local inv_pivot = 1.0 / pivot_val

		local unroll_lim = row_bytes - (row_bytes % 16)
		local byte_step = 0
		
		while byte_step < unroll_lim do
			writef32(work_buffer, pivot_row_offset + byte_step, readf32(work_buffer, pivot_row_offset + byte_step) * inv_pivot)
			writef32(inverse_buffer, pivot_row_offset + byte_step, readf32(inverse_buffer, pivot_row_offset + byte_step) * inv_pivot)
			
			writef32(work_buffer, pivot_row_offset + byte_step + 4, readf32(work_buffer, pivot_row_offset + byte_step + 4) * inv_pivot)
			writef32(inverse_buffer, pivot_row_offset + byte_step + 4, readf32(inverse_buffer, pivot_row_offset + byte_step + 4) * inv_pivot)
			
			writef32(work_buffer, pivot_row_offset + byte_step + 8, readf32(work_buffer, pivot_row_offset + byte_step + 8) * inv_pivot)
			writef32(inverse_buffer, pivot_row_offset + byte_step + 8, readf32(inverse_buffer, pivot_row_offset + byte_step + 8) * inv_pivot)
			
			writef32(work_buffer, pivot_row_offset + byte_step + 12, readf32(work_buffer, pivot_row_offset + byte_step + 12) * inv_pivot)
			writef32(inverse_buffer, pivot_row_offset + byte_step + 12, readf32(inverse_buffer, pivot_row_offset + byte_step + 12) * inv_pivot)
			
			byte_step += 16
		end
		
		while byte_step < row_bytes do
			writef32(work_buffer, pivot_row_offset + byte_step, readf32(work_buffer, pivot_row_offset + byte_step) * inv_pivot)
			writef32(inverse_buffer, pivot_row_offset + byte_step, readf32(inverse_buffer, pivot_row_offset + byte_step) * inv_pivot)
			byte_step += 4
		end

		for targ_row = 0, size_n - 1 do 
			if targ_row ~= pivot_col then 
				local targ_row_offset = targ_row * row_bytes
				local factor = readf32(work_buffer, targ_row_offset + (pivot_col * 4))
				if factor ~= 0.0 then
					local unroll_inner = row_bytes - (row_bytes % 16)
					local byte_inner = 0
					
					while byte_inner < unroll_inner do
						local i_targ = targ_row_offset + byte_inner
						local i_pivot = pivot_row_offset + byte_inner
						
						writef32(work_buffer, i_targ, readf32(work_buffer, i_targ) - factor * readf32(work_buffer, i_pivot))
						writef32(inverse_buffer, i_targ, readf32(inverse_buffer, i_targ) - factor * readf32(inverse_buffer, i_pivot))
						
						writef32(work_buffer, i_targ + 4, readf32(work_buffer, i_targ + 4) - factor * readf32(work_buffer, i_pivot + 4))
						writef32(inverse_buffer, i_targ + 4, readf32(inverse_buffer, i_targ + 4) - factor * readf32(inverse_buffer, i_pivot + 4))
						
						writef32(work_buffer, i_targ + 8, readf32(work_buffer, i_targ + 8) - factor * readf32(work_buffer, i_pivot + 8))
						writef32(inverse_buffer, i_targ + 8, readf32(inverse_buffer, i_targ + 8) - factor * readf32(inverse_buffer, i_pivot + 8))
						
						writef32(work_buffer, i_targ + 12, readf32(work_buffer, i_targ + 12) - factor * readf32(work_buffer, i_pivot + 12))
						writef32(inverse_buffer, i_targ + 12, readf32(inverse_buffer, i_targ + 12) - factor * readf32(inverse_buffer, i_pivot + 12))
						
						byte_inner += 16
					end
					
					while byte_inner < row_bytes do
						local i_targ = targ_row_offset + byte_inner
						local i_pivot = pivot_row_offset + byte_inner
						writef32(work_buffer, i_targ, readf32(work_buffer, i_targ) - factor * readf32(work_buffer, i_pivot))
						writef32(inverse_buffer, i_targ, readf32(inverse_buffer, i_targ) - factor * readf32(inverse_buffer, i_pivot))
						byte_inner += 4
					end
				end 
			end
		end 
	end

	return setmetatable({
		Rows = size_n,
    	Columns = size_n,
    	Data = inverse_buffer,
   		Parallel = self.Parallel
	}, Matrix)
end

-- MATH
 
function Matrix.__add(mat_a: Matrix, mat_b: Matrix): Matrix
	if not mat_a or not mat_b then
		error("Matrix addition: operands cannot be nil")
	end
	if mat_a.Data == nil or mat_b.Data == nil then
		error("Matrix addition: invalid matrix structure")
	end
	assert(mat_a.Rows == mat_b.Rows and mat_a.Columns == mat_b.Columns, "Matrix dimensions must match for addition.")
	local mat_a_data = mat_a.Data
	local mat_b_data = mat_b.Data
	local mat_a_rows = mat_a.Rows
	local mat_a_cols = mat_a.Columns

	local total_bytes = buffer.len(mat_a_data)
	local res_buffer = buffer.create(total_bytes)
	local last_byte_offset = total_bytes - 4

	for byte_offset = 0, last_byte_offset, 4 do 
		local buf_a_float = readf32(mat_a_data, byte_offset)
		local buf_b_float = readf32(mat_b_data, byte_offset)
		local sum = buf_a_float + buf_b_float
		
		writef32(res_buffer, byte_offset, sum)
	end

	return setmetatable({
		Rows = mat_a_rows,
		Columns = mat_a_cols,
		Data = res_buffer,
		Parallel = mat_a.Parallel
	}, Matrix)
end


function Matrix.__sub(mat_a: Matrix, mat_b: Matrix): Matrix
	if not mat_a or not mat_b then
		error("Matrix subtraction: operands cannot be nil")
	end
	if mat_a.Data == nil or mat_b.Data == nil then
		error("Matrix subtraction: invalid matrix structure")
	end
	assert(mat_a.Rows == mat_b.Rows and mat_a.Columns == mat_b.Columns, "Matrix dimensions must match for subtraction.")
	local mat_a_data = mat_a.Data
	local mat_b_data = mat_b.Data
	local mat_a_rows = mat_a.Rows
	local mat_a_cols = mat_a.Columns

	local total_bytes = buffer.len(mat_a_data)
	local res_buffer = buffer.create(total_bytes)
	local last_byte_offset = total_bytes - 4

	for byte_offset = 0, last_byte_offset, 4 do 
		local buf_a_float = readf32(mat_a_data, byte_offset)
		local buf_b_float = readf32(mat_b_data, byte_offset)
		local sub = buf_a_float - buf_b_float
		
		writef32(res_buffer, byte_offset, sub)
	end

	return setmetatable({
		Rows = mat_a_rows,
		Columns = mat_a_cols,
		Data = res_buffer,
		Parallel = mat_a.Parallel
	}, Matrix)
end

Matrix.__div = function(a: Matrix, b: Matrix)
	error("Cannot divide matrices.")
end

local function multiplyScalar(src_matrix: Matrix, scalar: number): Matrix
	if src_matrix.Data == nil or src_matrix.Rows == nil or src_matrix.Columns == nil then
		error("_MultiplyInternal: invalid matrix structure")
	end

	local srcmat_data = src_matrix.Data
	local total_bytes = buffer.len(srcmat_data)
	local result_buffer = buffer.create(total_bytes)

	for byte_offset = 0, total_bytes - 4, 4 do
		writef32(result_buffer, byte_offset, readf32(srcmat_data, byte_offset) * scalar)
	end

	return setmetatable({
		Rows = src_matrix.Rows,
		Columns = src_matrix.Columns,
		Data = result_buffer,
		Parallel = src_matrix.Parallel
	}, Matrix)
end

-- An internal function, best not to run.
function Matrix._MultiplyInternal(self: Matrix | number, oper_r: Matrix | number, allow_parallel: boolean): Matrix
	if oper_r == nil then
		error("_MultiplyInternal: operand cannot be nil")
	end

	if type(self) == "number" then
		if type(oper_r) ~= "table" then
			error("_MultiplyInternal: cannot multiply two scalars")
		end
		return multiplyScalar(oper_r, self)
	elseif type(oper_r) == "number" then
		if type(self) ~= "table" then
			error("_MultiplyInternal: cannot multiply two scalars")
		end
		return multiplyScalar(self, oper_r)
	end

	-- MAT x MAT
	if self.Data == nil or oper_r.Data == nil or self.Rows == nil or oper_r.Rows == nil then
		error("_MultiplyInternal: invalid matrix structure detected")
	end

	assert(self.Columns == oper_r.Rows, "Unable to perform matrix mul, oper_l.Columns does not match oper_r.Rows.")
	local Rows_a = self.Rows
	local shared_k = self.Columns
	local Cols_b = oper_r.Columns

	local use_parallel = (self.Parallel or oper_r.Parallel) and ((Rows_a * Cols_b) >= 4096)
	assert(not use_parallel or allow_parallel, "Parallel matrix multiplication cannot use *; call A:Multiply(B) instead.")
	assert(not use_parallel or coroutine.isyieldable(), "Parallel matrix multiplication must be called from a yieldable thread.")

	local cache = oper_r._transposedCache
	if not cache or oper_r._dirty or cache.source ~= oper_r.Data or cache.rows ~= oper_r.Rows or cache.columns ~= oper_r.Columns then
		nextCacheId += 1
		cache = {
			rows = oper_r.Rows,
			columns = oper_r.Columns,
			source = oper_r.Data,
			data = oper_r:Transpose().Data,
			id = nextCacheId,
		}
		oper_r._transposedCache = cache
		oper_r._dirty = false
	end
	local transpose = assert(cache)
	local buffer_a = self.Data
	local buffer_bt = transpose.data

	local result_bytes = Rows_a * Cols_b * 4
	local result_buffer = buffer.create(result_bytes)

	local row_bytes_a = shared_k * 4
	local row_bytes_c = Cols_b * 4

	-- PARALLEL
	if use_parallel then 
		local rows_per_worker = math.ceil(Rows_a / WORKER_COUNT)
		local active_workers = math.min(WORKER_COUNT, math.ceil(Rows_a / rows_per_worker))
		local completed_workers = 0
		local expected_workers = active_workers
		local sent_workers = 0
		local worker_error: string? = nil
		local canReuseWorkerCache = activeJobs == 0
		if not canReuseWorkerCache then
			table.clear(workerCaches)
		end
		activeJobs += 1

		nextJobId += 1
		local job_id = nextJobId

		local calling_thread = coroutine.running()

		local connection = replyEvent.Event:Connect(function(job: number, workerID: number, startRow: number, sliceBuffer: buffer?, failure: string?)
			if job ~= job_id then return end
			if failure then
				worker_error = worker_error or ("Matrix worker " .. workerID .. " failed: " .. failure)
			elseif sliceBuffer == nil then
				worker_error = worker_error or ("Matrix worker " .. workerID .. " returned nil buffer")
			else
				local dest_byte_offset = startRow * row_bytes_c
				buffer.copy(result_buffer, dest_byte_offset, sliceBuffer, 0, buffer.len(sliceBuffer))
			end
			completed_workers += 1

			if completed_workers == expected_workers then
				task.defer(calling_thread)
			end
		end)

		local dispatched, dispatch_error = pcall(function()
			for w_idx = 0, active_workers - 1 do
				local start_row = w_idx * rows_per_worker
				local end_row = math.min(start_row + rows_per_worker - 1, Rows_a - 1)
				local slice_rows = (end_row - start_row) + 1
				local slice_bytes = slice_rows * row_bytes_a
				local slice_a = buffer.create(slice_bytes)
				buffer.copy(slice_a, 0, buffer_a, start_row * row_bytes_a, slice_bytes)

				local actor = workerPool[w_idx + 1]
				if not actor then
					error("Worker " .. (w_idx + 1) .. " not initialized")
				end
	
				local workerIndex = w_idx + 1
				local workerBuffer = if canReuseWorkerCache and workerCaches[workerIndex] == transpose.id then nil else buffer_bt
				actor:SendMessage('MulSlice', job_id, workerIndex, slice_a, workerBuffer, transpose.id, canReuseWorkerCache, start_row, slice_rows, shared_k, Cols_b, replyEvent)
				sent_workers += 1
				if canReuseWorkerCache then
					workerCaches[workerIndex] = transpose.id
				end
			end
		end)

		if not dispatched then
			table.clear(workerCaches)
			expected_workers = sent_workers
		end
		if expected_workers > 0 then
			coroutine.yield()
		end
		connection:Disconnect()
		activeJobs -= 1
		
		if not dispatched then
			error("Failed to dispatch matrix multiplication: " .. tostring(dispatch_error))
		end
		if worker_error then
			error(worker_error)
		end

		return setmetatable({
			Rows = Rows_a,
			Columns = Cols_b,
			Data = result_buffer,
			Parallel = true
		}, Matrix)
	end


	-- NOT PARALLEL
	local unrolled_lim = row_bytes_a - (row_bytes_a % 16)

	for row_i = 0, Rows_a - 1 do
		local row_offset_a = row_i * row_bytes_a
		local row_offset_c = row_i * row_bytes_c

		for col_j = 0, Cols_b - 1 do
			local row_offset_bt = col_j * row_bytes_a

			local s_0, s_1, s_2, s_3 = 0.0, 0.0, 0.0, 0.0
			local byte_step = 0

			while byte_step < unrolled_lim do 
				local i_a = row_offset_a + byte_step
				local i_b = row_offset_bt + byte_step

				s_0 += readf32(buffer_a, i_a) * readf32(buffer_bt, i_b)
				s_1 += readf32(buffer_a, i_a + 4) * readf32(buffer_bt, i_b + 4)
				s_2 += readf32(buffer_a, i_a + 8) * readf32(buffer_bt, i_b + 8)
				s_3 += readf32(buffer_a, i_a + 12) * readf32(buffer_bt, i_b + 12)

				byte_step += 16
				
			end

			local total_sum = (s_0 + s_1) + (s_2 + s_3)

			while byte_step < row_bytes_a do 
				total_sum += readf32(buffer_a, row_offset_a + byte_step) * readf32(buffer_bt, row_offset_bt + byte_step)
				byte_step += 4
			end

			writef32(result_buffer, row_offset_c + (col_j * 4), total_sum)
		end 
	end

	return setmetatable({
		Rows = Rows_a,
		Columns = Cols_b,
		Data = result_buffer,
		Parallel = self.Parallel
	}, Matrix)
end

--[[
	Returns the product between two matrices.
	@param oper_r The operand / matrix that would be to the right.
]]
function Matrix.Multiply(self: Matrix, oper_r: Matrix | number): Matrix
	if oper_r == nil then
		error("Multiply: operand cannot be nil")
	end
	return self:_MultiplyInternal(oper_r, true)
end

function Matrix.__mul(oper_l: Matrix | number, oper_r: Matrix | number): Matrix
	if oper_l == nil or oper_r == nil then
		error("Matrix multiplication: operands cannot be nil")
	end
	if type(oper_l) == "number" then
		assert(type(oper_r) ~= "number", "Matrix multiplication requires a matrix operand.")
		return oper_r:_MultiplyInternal(oper_l, false)
	end
	return oper_l:_MultiplyInternal(oper_r, false)
end

return Matrix
