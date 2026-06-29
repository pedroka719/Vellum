$baseDir = "D:\roblox-executor-mcp\vellum"
$output = "$baseDir\bundle_fixed.lua"

function Read-File($path) { return [System.IO.File]::ReadAllText($path) }

function Wrap-Module($varName, $filePath, $level) {
    $src = Read-File $filePath
    $open = "[" + ("=" * $level) + "["
    $close = "]" + ("=" * $level) + "]"
    if ($src.Contains($close)) {
        return Wrap-Module $varName $filePath ($level + 1)
    }
    return "local $varName = embed($open`r`n$src`r`n$close)"
}

$parts = @()
$parts += @"
-- Vellum — Blox Fruits Bundle (self-contained, with fixes)
-- Execute this directly in your executor. No HTTP fetches needed.
local function embed(src)
	local fn, err = loadstring(src, "embed")
	if not fn then error("Bundle embed error: " .. tostring(err), 0) end
	return fn()
end

"@

$parts += (Wrap-Module "Theme" "$baseDir\lib\theme.lua" 4)
$parts += "`r`n`r`n"
$parts += (Wrap-Module "Helpers" "$baseDir\lib\helpers.lua" 4)
$parts += "`r`n`r`n"
$parts += (Wrap-Module "Toast" "$baseDir\lib\toast.lua" 8)
$parts += "`r`n`r`n"
$parts += (Wrap-Module "UI" "$baseDir\lib\ui.lua" 8)
$parts += "`r`n`r`n"
$parts += (Wrap-Module "ESP" "$baseDir\lib\esp.lua" 4)

$parts += @"

local lib = {
	theme   = Theme,
	helpers = Helpers,
	toast   = Toast,
	ui      = UI,
	esp     = ESP,
}

"@

$parts += (Wrap-Module "Game" "$baseDir\games\blox_fruits.lua" 8)

$parts += @"

local ok, err = xpcall(Game.start, debug.traceback, lib)
_G.VELLUM_OK = ok
_G.VELLUM_ERR = tostring(err)
if not ok then
	warn("[Vellum BUNDLE ERROR]", tostring(err))
	print("[Vellum BUNDLE ERROR]", tostring(err))
end
"@

$full = $parts -join ""
[System.IO.File]::WriteAllText($output, $full, [System.Text.UTF8Encoding]::new($false))
$len = $full.Length
Write-Host "Bundle written: $output ($len bytes)"
