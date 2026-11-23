local product=require("product")
function love.conf(t)
    t.identity="pot"
    t.version="11.5"
    t.window.title=product=="studio" and "Pot Studio" or "Pot Client"
    t.window.width=product=="studio" and 1360 or 1180
    t.window.height=820
    t.window.resizable=true
    t.window.minwidth=product=="studio" and 920 or 720
    t.window.minheight=product=="studio" and 680 or 540
    t.window.highdpi=true
    t.window.vsync=1
    t.modules.audio=false
    t.modules.joystick=false
    t.modules.physics=false
end
