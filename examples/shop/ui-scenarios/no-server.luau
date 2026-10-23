-- The same menu with no server running: the scenario stands in for it with ui.remote and
-- ui.fireClient. Handy when the real server needs things that can't run offline.
return {
	run = function(ui)
		ui.remote("ReplicatedStorage.ShopRemotes.Buy", function(_player, itemId)
			return { ok = false, reason = `The shop is closed (asked for {itemId})` }
		end, "RemoteFunction")
		ui.fireClient("ReplicatedStorage.ShopRemotes.StateChanged", 99999, { "blob", "pip", "mossy" })
		ui.boot()
		ui.click("ShopGui/ShopButton/Button")
		ui.click("ShopGui/Window/Grid/ember")
		ui.click("ShopGui/Window/Detail/Buy/Button")
		ui.shot("closed")
	end,
}
