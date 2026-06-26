-- Vellum — UI builder factories
-- Themed widget constructors used by every game module so the visual
-- language stays consistent across the hub.

-- TODO(skeleton):
-- 1. Move from spin_soccer_full.lua:
--    - root window + header + sidebar + content panel + drag handler
--    - newPage, newTab, repaintTab + accent strip
--    - row, sectionLabel
--    - toggleRow + multiToggleRow (iOS-style animated pill)
--    - intervalRow
--    - actionBtn (with hover state)
-- 2. Accept a `parent` arg or return a `mount(gui)` function so game modules
--    can decide where the UI lives
-- 3. Return: { mount, newPage, newTab, toggleRow, multiToggleRow, intervalRow,
--             actionBtn, sectionLabel, row }

return {}
