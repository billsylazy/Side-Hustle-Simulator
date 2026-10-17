-- RebirthWatcher: fires the big full-screen celebration when the server
-- confirms a rebirth. INSUFFICIENT and other variants are handled by the
-- Rebirth panel UI, not here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientEffects = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientEffects"))

local RebirthWatcher = {}

function RebirthWatcher.start()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local rebirthResult = remotes:WaitForChild("RebirthResult")
		rebirthResult.OnClientEvent:Connect(function(status, newRebirths, _newMultiplier)
			if status ~= "SUCCESS" then
				return -- e.g. "INSUFFICIENT": the Rebirth panel shows that
			end
			if type(newRebirths) ~= "number" then
				return
			end
			ClientEffects.celebrate(newRebirths)
		end)
	end)
end

return RebirthWatcher
