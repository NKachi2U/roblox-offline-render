-- The open shop on a landscape phone screen, with element outlines to spot overlaps.
return {
	size = "844x390",
	run = function(ui)
		ui.boot({ server = true })
		ui.click("ShopGui/ShopButton/Button")
		ui.shot("phone")
		ui.shot("phone-outlined", { outline = true })
		ui.dump("ShopGui/Window", { depth = 2 })
	end,
}
