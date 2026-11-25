--!strict
--!native
--!optimize 2

local readf32 = buffer.readf32
local writef32 = buffer.writef32

local function multiplySlice(sliceA: buffer, bufferBT: buffer, sliceRows: number, sharedK: number, colsB: number): buffer
	local slice_buffer = buffer.create(sliceRows * colsB * 4)
	local row_bytes_a = sharedK * 4
	local row_bytes_c = colsB * 4
	local unrolled_lim = row_bytes_a - (row_bytes_a % 16)
	local tiled_columns = colsB - colsB % 4
	local last_yield = os.clock()
	local l_row = 0

	while l_row + 3 < sliceRows do
		local r0_a = l_row * row_bytes_a
		local r1_a = r0_a + row_bytes_a
		local r2_a = r1_a + row_bytes_a
		local r3_a = r2_a + row_bytes_a

		local r0_c = l_row * row_bytes_c
		local r1_c = r0_c + row_bytes_c
		local r2_c = r1_c + row_bytes_c
		local r3_c = r2_c + row_bytes_c

		for col_j = 0, tiled_columns - 1, 4 do
			local s00, s01, s02, s03 = 0.0, 0.0, 0.0, 0.0
			local s10, s11, s12, s13 = 0.0, 0.0, 0.0, 0.0
			local s20, s21, s22, s23 = 0.0, 0.0, 0.0, 0.0
			local s30, s31, s32, s33 = 0.0, 0.0, 0.0, 0.0
			local b0_offset = col_j * row_bytes_a
			local b1_offset = b0_offset + row_bytes_a
			local b2_offset = b1_offset + row_bytes_a
			local b3_offset = b2_offset + row_bytes_a
			for k_start = 0, row_bytes_a - 1, 2048 do
				local k_end = math.min(k_start + 2048, row_bytes_a)
				for k = k_start, k_end - 1, 4 do
					local a0, a1 = readf32(sliceA, r0_a + k), readf32(sliceA, r1_a + k)
					local a2, a3 = readf32(sliceA, r2_a + k), readf32(sliceA, r3_a + k)
					local b0, b1 = readf32(bufferBT, b0_offset + k), readf32(bufferBT, b1_offset + k)
					local b2, b3 = readf32(bufferBT, b2_offset + k), readf32(bufferBT, b3_offset + k)
					s00 += a0 * b0; s01 += a0 * b1; s02 += a0 * b2; s03 += a0 * b3
					s10 += a1 * b0; s11 += a1 * b1; s12 += a1 * b2; s13 += a1 * b3
					s20 += a2 * b0; s21 += a2 * b1; s22 += a2 * b2; s23 += a2 * b3
					s30 += a3 * b0; s31 += a3 * b1; s32 += a3 * b2; s33 += a3 * b3
				end
			end
			local col_byte = col_j * 4
			writef32(slice_buffer, r0_c + col_byte, s00); writef32(slice_buffer, r0_c + col_byte + 4, s01); writef32(slice_buffer, r0_c + col_byte + 8, s02); writef32(slice_buffer, r0_c + col_byte + 12, s03)
			writef32(slice_buffer, r1_c + col_byte, s10); writef32(slice_buffer, r1_c + col_byte + 4, s11); writef32(slice_buffer, r1_c + col_byte + 8, s12); writef32(slice_buffer, r1_c + col_byte + 12, s13)
			writef32(slice_buffer, r2_c + col_byte, s20); writef32(slice_buffer, r2_c + col_byte + 4, s21); writef32(slice_buffer, r2_c + col_byte + 8, s22); writef32(slice_buffer, r2_c + col_byte + 12, s23)
			writef32(slice_buffer, r3_c + col_byte, s30); writef32(slice_buffer, r3_c + col_byte + 4, s31); writef32(slice_buffer, r3_c + col_byte + 8, s32); writef32(slice_buffer, r3_c + col_byte + 12, s33)
		end

		for col_j = tiled_columns, colsB - 1 do
			local row_offset_bt = col_j * row_bytes_a
			local s0_0, s0_1, s0_2, s0_3 = 0.0, 0.0, 0.0, 0.0
			local s1_0, s1_1, s1_2, s1_3 = 0.0, 0.0, 0.0, 0.0
			local s2_0, s2_1, s2_2, s2_3 = 0.0, 0.0, 0.0, 0.0
			local s3_0, s3_1, s3_2, s3_3 = 0.0, 0.0, 0.0, 0.0
			local byte_step = 0

			while byte_step < unrolled_lim do
				local b0 = readf32(bufferBT, row_offset_bt + byte_step)
				local b1 = readf32(bufferBT, row_offset_bt + byte_step + 4)
				local b2 = readf32(bufferBT, row_offset_bt + byte_step + 8)
				local b3 = readf32(bufferBT, row_offset_bt + byte_step + 12)

				local ia0 = r0_a + byte_step
				s0_0 += readf32(sliceA, ia0) * b0
				s0_1 += readf32(sliceA, ia0 + 4) * b1
				s0_2 += readf32(sliceA, ia0 + 8) * b2
				s0_3 += readf32(sliceA, ia0 + 12) * b3

				local ia1 = r1_a + byte_step
				s1_0 += readf32(sliceA, ia1) * b0
				s1_1 += readf32(sliceA, ia1 + 4) * b1
				s1_2 += readf32(sliceA, ia1 + 8) * b2
				s1_3 += readf32(sliceA, ia1 + 12) * b3

				local ia2 = r2_a + byte_step
				s2_0 += readf32(sliceA, ia2) * b0
				s2_1 += readf32(sliceA, ia2 + 4) * b1
				s2_2 += readf32(sliceA, ia2 + 8) * b2
				s2_3 += readf32(sliceA, ia2 + 12) * b3

				local ia3 = r3_a + byte_step
				s3_0 += readf32(sliceA, ia3) * b0
				s3_1 += readf32(sliceA, ia3 + 4) * b1
				s3_2 += readf32(sliceA, ia3 + 8) * b2
				s3_3 += readf32(sliceA, ia3 + 12) * b3

				byte_step += 16
			end

			local sum0 = (s0_0 + s0_1) + (s0_2 + s0_3)
			local sum1 = (s1_0 + s1_1) + (s1_2 + s1_3)
			local sum2 = (s2_0 + s2_1) + (s2_2 + s2_3)
			local sum3 = (s3_0 + s3_1) + (s3_2 + s3_3)

			while byte_step < row_bytes_a do
				local b = readf32(bufferBT, row_offset_bt + byte_step)
				sum0 += readf32(sliceA, r0_a + byte_step) * b
				sum1 += readf32(sliceA, r1_a + byte_step) * b
				sum2 += readf32(sliceA, r2_a + byte_step) * b
				sum3 += readf32(sliceA, r3_a + byte_step) * b
				byte_step += 4
			end

			local col_byte = col_j * 4
			writef32(slice_buffer, r0_c + col_byte, sum0)
			writef32(slice_buffer, r1_c + col_byte, sum1)
			writef32(slice_buffer, r2_c + col_byte, sum2)
			writef32(slice_buffer, r3_c + col_byte, sum3)
		end

		if os.clock() - last_yield >= 0.04 then
			task.wait()
			last_yield = os.clock()
		end
		l_row += 4
	end

	while l_row < sliceRows do
		local row_offset_a = l_row * row_bytes_a
		local row_offset_c = l_row * row_bytes_c

		for col_j = 0, colsB - 1 do
			local row_offset_bt = col_j * row_bytes_a
			local s_0, s_1, s_2, s_3 = 0.0, 0.0, 0.0, 0.0
			local byte_step = 0

			while byte_step < unrolled_lim do
				local i_a = row_offset_a + byte_step
				local i_b = row_offset_bt + byte_step
				s_0 += readf32(sliceA, i_a) * readf32(bufferBT, i_b)
				s_1 += readf32(sliceA, i_a + 4) * readf32(bufferBT, i_b + 4)
				s_2 += readf32(sliceA, i_a + 8) * readf32(bufferBT, i_b + 8)
				s_3 += readf32(sliceA, i_a + 12) * readf32(bufferBT, i_b + 12)
				byte_step += 16
			end

			local total_sum = (s_0 + s_1) + (s_2 + s_3)
			while byte_step < row_bytes_a do
				total_sum += readf32(sliceA, row_offset_a + byte_step) * readf32(bufferBT, row_offset_bt + byte_step)
				byte_step += 4
			end
			writef32(slice_buffer, row_offset_c + (col_j * 4), total_sum)
		end
		l_row += 1
	end

	return slice_buffer
end

return function(actor: Actor): ()
	local cachedTransposes: {[number]: buffer} = {}
	actor:BindToMessageParallel("MulSlice", function(jobId: number, workerID: number, sliceA: buffer, bufferBT: buffer?, cacheId: number, exclusive: boolean, startRow: number, sliceRows: number, sharedK: number, colsB: number, replyEvent: BindableEvent)
		if bufferBT ~= nil then
			cachedTransposes[cacheId] = bufferBT
		else
			bufferBT = cachedTransposes[cacheId]
			if not bufferBT then
				task.synchronize()
				replyEvent:Fire(jobId, workerID, startRow, nil, "Cached transpose is unavailable")
				return
			end
		end
		local transpose = assert(bufferBT)
		if exclusive then
			cachedTransposes = {[cacheId] = transpose}
		end
		local ok, result = pcall(multiplySlice, sliceA, transpose, sliceRows, sharedK, colsB)
		task.synchronize()
		if ok then
			replyEvent:Fire(jobId, workerID, startRow, result, nil)
		else
			replyEvent:Fire(jobId, workerID, startRow, nil, tostring(result))
		end
	end)
	actor:SetAttribute("Ready", true)
end
