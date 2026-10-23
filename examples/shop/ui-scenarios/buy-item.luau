-- Buys an item through the real server script, then tries one the player can't afford.
-- Checks the result in numbers too, so a script can fail the run if the purchase didn't land.
return {
	run = function(ui)
		ui.boot({ server = true })
		ui.click("ShopGui/ShopButton/Button")
		ui.click("ShopGui/Window/Grid/pip")
		ui.click("ShopGui/Window/Detail/Buy/Button")
		ui.shot("bought")
		assert(ui.find("ShopGui/Wallet/Amount").Text == "950", "coins should drop from 1,250 to 950")

		ui.click("ShopGui/Window/Grid/goldie")
		ui.click("ShopGui/Window/Detail/Buy/Button")
		ui.shot("too-expensive", { crop = "ShopGui/Window" })
	end,
}
