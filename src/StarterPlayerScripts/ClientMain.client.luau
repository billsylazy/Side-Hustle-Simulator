-- ClientMain: client bootstrapper. Waits for the shared contract to exist,
-- then requires and starts every controller module. A broken controller is
-- warned about and skipped so the rest of the client still works.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The server creates Remotes at startup; Shared syncs in via Rojo/ReplicatedStorage.
ReplicatedStorage:WaitForChild("Shared")
ReplicatedStorage:WaitForChild("Remotes")

local controllersFolder = script.Parent:WaitForChild("Controllers")

for _, moduleScript in controllersFolder:GetChildren() do
	if not moduleScript:IsA("ModuleScript") then
		continue
	end

	local okRequire, controller = pcall(require, moduleScript)
	if not okRequire then
		warn(("[ClientMain] Failed to require controller %s: %s"):format(moduleScript.Name, tostring(controller)))
		continue
	end

	if type(controller) ~= "table" or type(controller.start) ~= "function" then
		warn(("[ClientMain] Controller %s does not expose start(); skipping"):format(moduleScript.Name))
		continue
	end

	local okStart, startError = pcall(controller.start)
	if not okStart then
		warn(("[ClientMain] Controller %s failed to start: %s"):format(moduleScript.Name, tostring(startError)))
	end
end
