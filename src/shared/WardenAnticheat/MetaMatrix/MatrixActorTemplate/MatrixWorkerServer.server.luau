--!strict

local actor = script:GetActor()
assert(actor, "MatrixWorkerServer must run inside an Actor")

require(script.Parent.MatrixWorker)(actor)
