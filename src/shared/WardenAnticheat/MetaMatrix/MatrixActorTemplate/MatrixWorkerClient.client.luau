--!strict

local actor = script:GetActor()
assert(actor, "MatrixWorkerClient must run inside an Actor")

require(script.Parent.MatrixWorker)(actor)
