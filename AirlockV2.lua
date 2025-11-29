-- AirLock 子电脑脚本（基于 CC:Tweaked）
-- 功能：
-- 1) 通过 rednet 接收来自主电脑的锁定/解锁消息（协议："airlock_lock"），
--    若被主电脑锁定则拒绝执行气闸命令。
-- 2) 通过 rednet 接收气闸控制命令（协议："airlock_control"），命令格式支持：
--    a) 表格消息：{ cmd = "open", side = "left"|"right", duration = <秒> }
--    b) 简短字符串："open_left" / "open_right"
-- 3) 根据配置的左右红石输出侧（默认 left/right）控制门的打开（true）/关闭（false）。
-- 4) 在执行过程中会拒绝并发请求并向发送方返回状态（"ok","locked","busy","error"）。
-- 5) 维护模式：只有 integrator 后方（back）有红石信号时才允许气闸循环

-- 使用说明：
-- 将本脚本放在子电脑上（label 可选）。确保子电脑有 modem（无线或有线）可用并能与主电脑通信。
-- 启动时可传入参数：
--   arg[1] = 左门红石侧（默认 "left"）
--   arg[2] = 右门红石侧（默认 "right"）
--   arg[3] = modem 侧（默认 "back"）
--   arg[4] = 默认打开持续时间（秒，默认 3）
--   arg[5] = monitor 侧（可选，默认自动查找）
--   arg[6] = 默认常开侧（"left" / "right" / "none"，默认 "left"）
--   arg[7] = 触发红石输入侧（默认 "back"）
--   arg[8] = 切换常开侧时的 gap（秒，默认 1）
-- 示例： lua AirLock.lua left right back 4

local leftSide = arg and arg[1] or "left"
local rightSide = arg and arg[2] or "right"
local modemSide = arg and arg[3] or "top"
local defaultDuration = tonumber(arg and arg[4]) or 14
-- 可选第5个参数：monitor 所在侧（例如 "top" / "left" / "back"），若不指定将尝试自动查找
local monitorSideArg = arg and arg[5] or nil
-- 可选第6个参数：默认常开侧，"left" 或 "right"；默认值为 "left"。传入 "none" 可禁用默认常开。
local defaultOpenSide = arg and arg[6] or "left"
-- 可选第7个参数：触发气闸循环的红石输入侧（默认 "back"）
local triggerSide = arg and arg[7] or "front"

local locked = false -- 是否被主电脑锁定
local busy = false   -- 是否正在执行开门动作（防止并发）
local maintenanceMode = false -- 维护模式状态
local rednetOpened = false
local monitor = nil  -- monitor peripheral 对象（若有）
local integrator = nil -- redstoneIntegrator peripheral 对象
local status = "Normal" -- 显示状态: "Working","Normal","Emergency","Maintenance"
-- 最小重触发间隔（arg[9]，秒），默认 0 表示无额外冷却
local minRetrigger = tonumber(arg and arg[9]) or 30
local lastCycleTime = 0 -- 上次执行循环的高精度时间（os.clock）
-- 可选参数：按下后延迟发出一次脉冲（默认 5 秒，长度 0.5 秒，输出侧 bottom）
local pulseDelay = tonumber(arg and arg[10]) or 5
local pulseLength = tonumber(arg and arg[11]) or 0.5
local pulseSide = arg and arg[12] or "bottom"
local scheduledTimers = {} -- timerID -> callback
-- 气闸循环计数：每次 performCycle() 成功执行后自增。初始为 0。
local cycleCount = 0

-- 安全获取外设的通用函数
local function safeGetPeripheral(peripheralType, preferredSide)
    -- 如果指定了偏好侧，先尝试该侧
    if preferredSide and type(preferredSide) == "string" then
        local ok, per = pcall(function() return peripheral.wrap(preferredSide) end)
        if ok and per then
            -- 检查外设类型
            if peripheralType == "monitor" and type(per.clear) == "function" then
                return per
            elseif peripheralType == "redstoneIntegrator" and type(per.setOutput) == "function" then
                return per
            elseif peripheralType == "modem" and type(per.isOpen) == "function" then
                return per
            end
        end
    end
    
    -- 自动查找
    local ok, found = pcall(function() return peripheral.find(peripheralType) end)
    if ok and found then
        return found
    end
    
    -- 如果没找到，尝试在所有侧查找
    for _, side in ipairs({"left","right","top","bottom","front","back"}) do
        local ok, per = pcall(function() return peripheral.wrap(side) end)
        if ok and per then
            if peripheralType == "monitor" and type(per.clear) == "function" then
                return per
            elseif peripheralType == "redstoneIntegrator" and type(per.setOutput) == "function" then
                return per
            elseif peripheralType == "modem" and type(per.isOpen) == "function" then
                return per
            end
        end
    end
    
    return nil
end

-- 初始化外设
local function initializePeripherals()
    -- 获取 monitor
    monitor = safeGetPeripheral("monitor", monitorSideArg)
    
    -- 获取 redstoneIntegrator
    integrator = safeGetPeripheral("redstoneIntegrator")
    
    -- 初始化 modem 和 rednet
    local modem = safeGetPeripheral("modem", modemSide)
    if modem then
        local success = false
        pcall(function()
            -- 找到 modem 所在的侧
            for _, side in ipairs({"left","right","top","bottom","front","back"}) do
                local per = peripheral.wrap(side)
                if per and per == modem then
                    success = rednet.open(side)
                    if success then
                        modemSide = side
                        break
                    end
                end
            end
        end)
        rednetOpened = success
    end
    
    return monitor ~= nil, integrator ~= nil, rednetOpened
end

local monitorFound, integratorFound, rednetInitialized = initializePeripherals()

-- 安全的红石输出函数
local function setOutput(sideName, state)
    if integratorFound then
        -- 使用 redstoneIntegrator
        local ok, err = pcall(function()
            integrator.setOutput(sideName, state)
        end)
        if not ok then
            return false, "Integrator error: " .. tostring(err)
        end
    else
        -- 回退到普通 redstone API
        local ok, err = pcall(function()
            redstone.setOutput(sideName, state)
        end)
        if not ok then
            return false, "Redstone error: " .. tostring(err)
        end
    end
    return true
end

-- 安全的红石输入函数
local function getInput(sideName)
    if integratorFound then
        local ok, result = pcall(function()
            return integrator.getInput(sideName)
        end)
        if ok then return result end
    end
    
    -- 回退到普通 redstone API
    local ok, result = pcall(function()
        return redstone.getInput(sideName)
    end)
    if ok then return result end
    
    return false
end

-- 检查维护模式条件：只有在 integrator back 侧有红石信号时才允许循环
local function checkMaintenanceModeCondition()
    if not maintenanceMode then
        return true -- 非维护模式，总是允许
    end
    
    -- 维护模式下，检查 integrator back 侧是否有信号
    local backSignal = getInput("back")
    if backSignal then
        log("Maintenance mode: back signal detected, allowing cycle")
        return true
    else
        log("Maintenance mode: no back signal, blocking cycle")
        return false
    end
end

local function schedulePulse(delay, side, length)
    local ok, tid = pcall(function() return os.startTimer(delay) end)
    if not ok or not tid then return end
    scheduledTimers[tid] = function()
        pcall(function()
            setOutput(side, true)
            sleep(length)
            setOutput(side, false)
        end)
    end
end

local function updateDisplay()
    if not monitor then return end
    local ok, w, h = pcall(function() return monitor.getSize() end)
    if not ok or not w or not h then return end
    monitor.clear()
    
    -- 设置背景为黑
    pcall(function() 
        monitor.setBackgroundColor(colors.black) 
        monitor.setTextScale(1)
    end)
    
    -- 主状态显示
    local displayStatus = status
    local statusColor = colors.white
    
    if maintenanceMode then
        displayStatus = "Maintenance Mode"
        statusColor = colors.orange
    elseif status == "Normal" then 
        statusColor = colors.green
    elseif status == "Working" then 
        statusColor = colors.yellow
    elseif status == "Emergency" then 
        statusColor = colors.red
    end
    
    -- 状态行（第一行或居中高度，取决于显示器高度）
    local statusLine = 1
    if h >= 3 then statusLine = 1 else statusLine = math.max(1, math.floor(h / 2)) end
    local tx = math.max(1, math.floor((w - #displayStatus) / 2) + 1)
    
    pcall(function()
        monitor.setCursorPos(tx, statusLine)
        monitor.setTextColor(statusColor)
        monitor.write(displayStatus)
    end)
    
    -- 维护模式详细信息
    if maintenanceMode then
        local backSignal = getInput("back")
        local conditionText = "Back Signal: " .. (backSignal and "YES" or "NO")
        local tx2 = math.max(1, math.floor((w - #conditionText) / 2) + 1)
        local infoY = math.min(h, statusLine + 1)
        
        pcall(function()
            monitor.setCursorPos(tx2, infoY)
            monitor.setTextColor(backSignal and colors.lime or colors.red)
            monitor.write(conditionText)
        end)
        
        -- 如果还有空间，显示说明
        if h >= statusLine + 2 then
            local helpText = "Signal required for cycles"
            local tx3 = math.max(1, math.floor((w - #helpText) / 2) + 1)
            pcall(function()
                monitor.setCursorPos(tx3, statusLine + 2)
                monitor.setTextColor(colors.white)
                monitor.write(helpText)
            end)
        end
    else
        -- 正常模式下的信息显示
        local cyclesText = "Cycles: " .. tostring(cycleCount or 0)
        local cooldown = 0
        if cycleCount == 0 then
            cooldown = 0
        else
            cooldown = math.max(0, (minRetrigger or 0) - (os.clock() - (lastCycleTime or 0)))
        end
        local cdText = "Cooldown: " .. string.format("%.1f", cooldown) .. "s"
        local infoLine = cyclesText .. "  " .. cdText
        local infoY = math.min(h, statusLine + 1)
        local tx2 = math.max(1, math.floor((w - #infoLine) / 2) + 1)
        
        pcall(function()
            monitor.setCursorPos(tx2, infoY)
            monitor.setTextColor(colors.white)
            monitor.write(infoLine)
        end)
    end
    
    -- 在显示器底部显示外设状态
    if h >= (maintenanceMode and 4 or 3) then
        pcall(function()
            local bottomLine = h
            monitor.setCursorPos(1, bottomLine)
            local peripheralStatus = "M:" .. (monitorFound and "Y" or "N") .. 
                                   " I:" .. (integratorFound and "Y" or "N") .. 
                                   " R:" .. (rednetOpened and "Y" or "N") ..
                                   " MT:" .. (maintenanceMode and "ON" or "OFF")
            monitor.setTextColor(colors.gray)
            monitor.write(peripheralStatus)
        end)
    end
end

local function log(...)
    print(os.date("%Y-%m-%d %H:%M:%S"), ...)
end

local function setDoor(sideName, state)
    -- state = true/false
    return setOutput(sideName, state)
end

-- 根据 defaultOpenSide/locked/busy/maintenanceMode 状态强制维护常开侧
local function enforceDefaultOpen()
    if not defaultOpenSide or defaultOpenSide == "none" then
        return
    end
    
    -- 在维护模式下，如果 back 侧没有信号，保持门关闭
    if maintenanceMode and not getInput("back") then
        pcall(function() setOutput(leftSide, false) end)
        pcall(function() setOutput(rightSide, false) end)
        return
    end
    
    if locked or busy then
        -- 锁定或忙时，确保两侧关闭
        pcall(function() setOutput(leftSide, false) end)
        pcall(function() setOutput(rightSide, false) end)
        return
    end
    -- 未锁定且不忙时，让 defaultOpenSide 为常开，另一侧关闭
    if defaultOpenSide == "left" then
        pcall(function() setOutput(leftSide, true) end)
        pcall(function() setOutput(rightSide, false) end)
    elseif defaultOpenSide == "right" then
        pcall(function() setOutput(leftSide, false) end)
        pcall(function() setOutput(rightSide, true) end)
    end
end

local function openDoor(sideName, duration)
    duration = duration or defaultDuration
    local ok, err = setDoor(sideName, true)
    if not ok then return false, err end
    sleep(duration)
    setDoor(sideName, false)
    return true
end

-- 执行完整的气闸循环（交换默认常开侧）：
-- 逻辑：若未锁定且空闲，切换 defaultOpenSide（left<->right），关闭两扇门，等待 gap 秒，
-- 然后打开新的 defaultOpenSide 并保持打开（直到下次循环或被锁定）。
local function performCycle()
    if locked then
        log("Cycle trigger ignored: locked")
        return false, "locked"
    end
    
    if busy then
        log("Cycle trigger ignored: busy")
        return false, "busy"
    end
    
    -- 检查维护模式条件
    if not checkMaintenanceModeCondition() then
        log("Cycle trigger ignored: maintenance mode condition not met")
        return false, "maintenance_blocked"
    end
    
    busy = true
    status = "Working"
    updateDisplay()

    -- 可选 gap 参数（arg[8]），若未指定则使用 defaultDuration
    local gap = tonumber(arg and arg[8]) or defaultDuration

    -- 记录触发时间并立即安排按下后延迟的脉冲（pulseDelay 以触发时刻为起点）
    lastCycleTime = os.clock()
    -- 增加气闸循环计数（用于控制冷却行为）
    cycleCount = cycleCount + 1
    log("Cycle count =", cycleCount)
    if pulseDelay and pulseDelay > 0 then
        schedulePulse(pulseDelay, pulseSide, pulseLength)
        log("Scheduled pulse to", pulseSide, "in", pulseDelay, "s, length", pulseLength)
    end

    -- 切换默认常开侧
    if defaultOpenSide == "left" then defaultOpenSide = "right" else defaultOpenSide = "left" end
    log("Switched default open side to", defaultOpenSide)

    -- 先关闭两扇门（进入封闭态）
    pcall(function() setOutput(leftSide, false) end)
    pcall(function() setOutput(rightSide, false) end)

    -- 等待 gap
    sleep(gap)

    -- 打开新的默认常开侧并保持打开
    if defaultOpenSide == "left" then
        pcall(function() setOutput(leftSide, true) end)
        pcall(function() setOutput(rightSide, false) end)
    else
        pcall(function() setOutput(leftSide, false) end)
        pcall(function() setOutput(rightSide, true) end)
    end

    busy = false
    if locked then 
        status = "Emergency" 
    elseif maintenanceMode then
        status = "Maintenance"
    else 
        status = "Normal" 
    end
    updateDisplay()
    enforceDefaultOpen()
    return true
end

-- 处理来自主电脑的锁定消息
local function handleLockMessage(msg)
    if type(msg) == "boolean" then
        locked = msg
    elseif type(msg) == "table" and msg.value ~= nil then
        locked = not not msg.value
    elseif type(msg) == "string" then
        if msg == "lock" then locked = true
        elseif msg == "unlock" then locked = false end
    end
    log("Locked state =", locked)
    -- 更新状态显示
    if locked then 
        status = "Emergency" 
    elseif maintenanceMode then
        status = "Maintenance"
    elseif busy then 
        status = "Working" 
    else 
        status = "Normal" 
    end
    updateDisplay()
    -- 根据锁定状态调整默认常开侧
    enforceDefaultOpen()
end

-- 处理维护模式消息
local function handleMaintenanceMessage(msg)
    if type(msg) == "boolean" then
        maintenanceMode = msg
    elseif type(msg) == "table" and msg.value ~= nil then
        maintenanceMode = not not msg.value
    elseif type(msg) == "string" then
        if msg == "maintenance_on" then maintenanceMode = true
        elseif msg == "maintenance_off" then maintenanceMode = false end
    end
    log("Maintenance mode =", maintenanceMode)
    
    -- 更新状态显示
    if locked then 
        status = "Emergency" 
    elseif maintenanceMode then
        status = "Maintenance"
    elseif busy then 
        status = "Working" 
    else 
        status = "Normal" 
    end
    updateDisplay()
    enforceDefaultOpen()
end

-- 处理控制消息（开门）
local function handleControlMessage(message, sender)
    if locked then
        if sender then rednet.send(sender, { status = "locked" }, "airlock_response") end
        return
    end
    
    -- 维护模式下也允许远程控制开门（用于测试）
    -- if maintenanceMode then
    --     if sender then rednet.send(sender, { status = "maintenance_blocked" }, "airlock_response") end
    --     return
    -- end
    
    if busy then
        if sender then rednet.send(sender, { status = "busy" }, "airlock_response") end
        return
    end

    local sideKey, duration
    if type(message) == "string" then
        if message == "open_left" then sideKey = "left"
        elseif message == "open_right" then sideKey = "right" end
    elseif type(message) == "table" then
        if message.cmd == "open" then sideKey = message.side end
        duration = tonumber(message.duration)
    end

    if not sideKey then
        if sender then rednet.send(sender, { status = "error", msg = "unknown command" }, "airlock_response") end
        return
    end

    local sideName = (sideKey == "left") and leftSide or rightSide
    busy = true
    status = "Working"
    updateDisplay()
    log("Opening ", sideKey, " -> side ", sideName, " for ", duration or defaultDuration, "s")
    local ok, err = pcall(openDoor, sideName, duration)
    busy = false
    if sender then
        if ok then 
            rednet.send(sender, { status = "ok" }, "airlock_response")
        else 
            rednet.send(sender, { status = "error", msg = tostring(err) }, "airlock_response") 
        end
    end
    -- 执行完成后根据锁定状态恢复显示并维持默认常开侧
    if locked then 
        status = "Emergency" 
    elseif maintenanceMode then
        status = "Maintenance"
    else 
        status = "Normal" 
    end
    updateDisplay()
    enforceDefaultOpen()
end

-- 主循环：接收 rednet 消息
log("AirLock subcomputer started", "left->", leftSide, " right->", rightSide, " modem->", modemSide, " trigger->", triggerSide)
log("Peripherals - Monitor:", monitorFound and "found" or "not found", 
    "Integrator:", integratorFound and "found" or "not found",
    "Rednet:", rednetOpened and "open" or "closed")

if not rednetOpened then
    log("Warning: no modem detected, rednet communication unavailable. Check modem connection or specify modem side.")
end
if monitor then
    log("Monitor detected: displaying status")
    updateDisplay()
else
    log("No monitor detected, status will not be displayed")
end
-- 启动时应用默认常开侧（如果配置）
enforceDefaultOpen()

-- 显示解析后的参数，便于调试
local parsedGap = tonumber(arg and arg[8]) or defaultDuration
log("Parsed parameters:",
    "leftSide=", leftSide,
    "rightSide=", rightSide,
    "modemSide=", modemSide,
    "defaultDuration=", defaultDuration,
    "monitorSide=", monitorSideArg or "(auto)",
    "defaultOpenSide=", defaultOpenSide,
    "triggerSide=", triggerSide,
    "gap=", parsedGap,
    "minRetrigger=", minRetrigger)

-- 将 rednet 循环与红石触发循环并行运行
local function rednetLoop()
    while true do
        local sender, message, protocol = rednet.receive(nil)
        -- message 可以是任意类型，protocol 是发消息时指定的协议名称
        if protocol == "airlock_lock" then
            handleLockMessage(message)
            -- 向发送方回执当前状态
            if sender then rednet.send(sender, { status = "ok", locked = locked }, "airlock_response") end
        elseif protocol == "airlock_control" then
            handleControlMessage(message, sender)
        elseif protocol == "airlock_maintenance" then
            handleMaintenanceMessage(message)
            -- 向发送方回执当前状态
            if sender then rednet.send(sender, { status = "ok", maintenance = maintenanceMode }, "airlock_response") end
        else
            -- 兼容性：如果 protocol 为 nil 或其他，尝试解析简单字符串命令
            if type(message) == "string" then
                if message == "lock" or message == "unlock" then
                    handleLockMessage(message)
                    if sender then rednet.send(sender, { status = "ok", locked = locked }, "airlock_response") end
                elseif message == "open_left" or message == "open_right" then
                    handleControlMessage(message, sender)
                elseif message == "maintenance_on" or message == "maintenance_off" then
                    handleMaintenanceMessage(message)
                    if sender then rednet.send(sender, { status = "ok", maintenance = maintenanceMode }, "airlock_response") end
                else
                    -- 未知消息，简单记录
                    log("Unknown message:", message, " protocol=", tostring(protocol))
                    if sender then rednet.send(sender, { status = "error", msg = "unknown" }, "airlock_response") end
                end
            else
                -- 记录并忽略
                log("Non-string/protocol message received, protocol=", tostring(protocol))
            end
        end
    end
end

local function redstoneTriggerLoop()
    -- Polling-based detection for rising edge on triggerSide.
    local last = getInput(triggerSide)
    while true do
        local current = getInput(triggerSide)
        if current and not last then
            -- rising edge detected
            local now = os.clock()
            -- 如果 cycleCount == 0 则取消冷却检查（首次允许立即触发），否则按 minRetrigger 检查冷却
            if cycleCount ~= 0 and now - lastCycleTime < minRetrigger then
                log("Ignored trigger on", triggerSide, "- cooldown", string.format("%.2f", minRetrigger), "s not passed (", string.format("%.2f", now - lastCycleTime), "s)")
            else
                log("Redstone trigger on", triggerSide, "detected - starting cycle")
                performCycle()
            end
        end
        last = current
        -- small sleep to avoid busy-loop; sleep accepts fractional seconds in CC:Tweaked
        sleep(0.05)
    end
end

-- 计时器事件循环：处理预定的定时器回调
local function timerLoop()
    while true do
        local ev, id = os.pullEvent("timer")
        local cb = scheduledTimers[id]
        if cb then
            scheduledTimers[id] = nil
            pcall(cb)
        end
    end
end

parallel.waitForAny(rednetLoop, redstoneTriggerLoop, timerLoop)