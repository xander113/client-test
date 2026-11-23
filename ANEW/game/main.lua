local Backend=require("backend")
local product=require("product")
local App=require(product)
local backend,app,startupError

function love.load()
    love.keyboard.setKeyRepeat(true)
    love.graphics.setDefaultFilter("linear","linear")
    pcall(function() love.window.setIcon(love.image.newImageData("icon.png")) end)
    local ok,value=pcall(Backend.new,function(event) if app then app:event(event) end end)
    if not ok then startupError=tostring(value); return end
    backend=value
    app=App.new(backend)
end
function love.update(dt)
    if backend then backend:pump() end
    if app then app:update(dt) end
end
function love.draw()
    love.graphics.clear(.96,.97,.95)
    if app then app:draw()
    elseif startupError then love.graphics.setColor(.2,.3,.22); love.graphics.printf(startupError,30,45,love.graphics.getWidth()-60) end
end
for _,event in ipairs({"mousepressed","mousereleased","mousemoved","wheelmoved","keypressed","keyreleased","textinput","filedropped","focus"}) do
    love[event]=function(...) if app and app[event] then app[event](app,...) end end
end
function love.quit()
    if app and app.quit and app:quit() then return true end
    if backend then backend:close() end
end
