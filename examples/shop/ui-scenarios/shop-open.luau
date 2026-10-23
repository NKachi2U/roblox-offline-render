-- Opens the shop, then looks at each tab.
return {
	run = function(ui)
		ui.boot({ server = true })
		ui.click("ShopGui/ShopButton/Button")
		ui.click("ShopGui/Window/Grid/mossy")
		ui.shot("pets")
		ui.click("ShopGui/Window/Tabs/Trails")
		ui.shot("trails")
		ui.click("ShopGui/Window/Tabs/Boosts")
		ui.shot("boosts")
	end,
}
