--!nocheck
-- Syntax-check Luau source files with Lune:
--   lune run tools/check_luau.luau src/**/*.luau ui/**/*.lua
-- Exit code 1 if any file fails to compile.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local failures = 0

for _, path in process.args do
	local okRead, src = pcall(fs.readFile, path)
	if not okRead then
		failures += 1
		print("READ FAIL " .. path .. ": " .. tostring(src))
	else
		local ok, err = pcall(luau.compile, src)
		if ok then
			print("OK   " .. path)
		else
			failures += 1
			local firstLine = string.match(tostring(err), "[^\n]+") or tostring(err)
			print("FAIL " .. path .. ": " .. firstLine)
		end
	end
end

if failures > 0 then
	print(("FAILED: %d file(s)"):format(failures))
	process.exit(1)
end
print("ALL OK")
