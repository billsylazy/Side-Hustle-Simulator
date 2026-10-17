--!strict
-- Number abbreviation for chunky simulator UI: 1234 -> "1.2K", money(1234) -> "$1.2K"

local FormatNumber = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qd", "Qn" }

function FormatNumber.abbreviate(n: number): string
	if n ~= n or n == math.huge then
		return "0"
	end
	local negative = n < 0
	n = math.abs(n)
	local index = 1
	while n >= 1000 and index < #SUFFIXES do
		n /= 1000
		index += 1
	end
	local text: string
	if index == 1 then
		text = tostring(math.floor(n))
	else
		text = string.format("%.1f", n)
		text = (text:gsub("%.0$", "")) .. SUFFIXES[index]
	end
	if negative then
		text = "-" .. text
	end
	return text
end

function FormatNumber.money(n: number): string
	return "$" .. FormatNumber.abbreviate(n)
end

-- Full comma formatting for gate signs etc: 1234567 -> "1,234,567"
function FormatNumber.commas(n: number): string
	local text = tostring(math.floor(math.abs(n)))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	if n < 0 then
		formatted = "-" .. formatted
	end
	return formatted
end

return FormatNumber
