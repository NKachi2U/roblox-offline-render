-- The HUD before the shop is opened: coin counter and SHOP button.
return {
	run = function(ui)
		ui.boot({ server = true })
		ui.shot("hud")
	end,
}
