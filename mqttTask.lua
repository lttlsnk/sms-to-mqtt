module(..., package.seeall)

require "misc"
require "mqtt"
require "sim"
require "sms"
require "sys"

imei = misc.getImei()
config = {
    clientId = imei, -- 默认使用IMEI号
    username = "",
    password = "",
    server = "mqtt.host.com", -- mqtt服务器
    port = 1883,
    topics = {}
}

local oldStatus = {
    Batt= "",
    RemainUpdate = "",
    TotalData = "",
    RemainData = "",
}

-- MQTT Broker 参数配置
local ready = false
local timeloop = 0
local refresh = true
local Phone = ""
local phoneretry = 0
local TotalData = ""
local RemainData = ""
local FirstRun = true
local sent = false
local Mobile = ""


function isReady()
    return ready
end

-- 数据发送的消息队列
local msgQueue = {}

local function publish(topic, payload, qos, retain,cb)

    table.insert(msgQueue, {
        t = topic,
        p = payload,
        q = qos or 0,
        r = retain or 0,
        c = cb
    })
    sys.publish("APP_SOCKET_SEND_DATA") -- 终止接收等待，处理发送
end

function SmsFrom(num, text, datetime)
    log.info("SMS","from ",num," IN ",datetime," Context:", text)
    datetime = string.gsub(datetime,"(%d+)%p+(%d+)%p+(%d+)%p+(%d+):(%d+):(%d+).*","20%1-%2-%3 %4:%5:%6")
    context = {
        from = num,
        to = Phone,
        text = text,
        time = datetime
    }
    if num == "10001" then
        local loop=1
        for s in string.gmatch(text,"%d+%p%d+[gG][bB]") do
            if loop == 1 then
                TotalData = s
            elseif loop == 3 then
                RemainData = s
            end
            loop = loop +1
        end
        sent = false
        refresh = false
    elseif num == "10086" then
    elseif num == "10010" then
    
    elseif text == "PING" then
        sms.send(num,"PONG:"..num)
    elseif string.sub(text,1,4) == "PONG" then    
        Phone = string.sub(text,6)
        publish(config.topics.Phone, Phone, 0, 1)
    else
        publish(config.topics.SMS .. "/Receive/" .. num, json.encode(context), 0)
    end

    if oldStatus.TotalData ~= TotalData then
        publish(config.topics.TotalData, TotalData, 0, 1)
        oldStatus.TotalData = TotalData
    end
    if oldStatus.RemainData ~= RemainData then
        publish(config.topics.RemainData, RemainData, 0, 1)
        oldStatus.RemainData = RemainData
    end
end

function sendEnv()
    sim.setQueryNumber(true)
    
    if Phone == "" then
        ril.request("AT+CNUM")
        Phone = sim.getNumber()
        phoneretry = phoneretry + 1
    end
    if phoneretry ==3 and Phone == "" then
    -- 有些sim卡中没有写入号码，如果需要利用其它模块获取本模块号码，
    -- 请修改 pingPhone 变量为其它模块实际电话号码
        pingPhone="177xxxxxxxx"
        sms.send(pingPhone,"PING")
    end
    if string.len(Phone) > 11 then
        Phone = string.sub(Phone,3)
        publish(config.topics.Phone, Phone,0, 1)
    end

    if refresh and not sent then
        if MNC ~= "" and Mobile ~= "" then
            log.info("SMS","发送流量查询短信")
            if Mobile == "CT" then
                sms.send("10001","108")
            elseif Mobile == "CM" then

            elseif Mobile == "CU" then
                sms.send("10010","CXTCYL")
            end
            timeloop = 0
        else
            MNC = sim.getMnc()
            if Mobile == "" and MNC ~= "" then
                -- 中国移动
                if MNC == "00" or MNC == "02" or MNC == "07" then Mobile = "CM"
                -- 中国联通
                elseif MNC == "01" or MNC == "06" or MNC == "09" then Mobile = "CU"
                -- 中国电信
                elseif MNC == "03" or MNC == "05" or MNC == "11" then Mobile = "CT"
                -- 中国铁塔
                elseif MNC == "20" then Mobile = "CTT"
                end
            end
        end
        if FirstRun  and TotalData== "" then
            refresh = true
        else
            refresh = false
            FirstRun = false
        end
    end
    if refresh then
        sent = not sent
    end
    local status = {
        Batt = '"' ..tostring(misc.getVbatt()) .. '"',
        RemainUpdate = '"' .. tostring(1440-timeloop) .. '"',
        TotalData = TotalData,
        RemainData = RemainData
    }

    if oldStatus.RemainData ~= RemainData then
        publish(config.topics.RemainData, RemainData, 0, 1)
        oldStatus.RemainData = RemainData
    end
    if oldStatus.Batt ~= status.Batt then
        publish(config.topics.Batt, status.Batt, 0, 1)
        oldStatus.Batt = status.Batt
    end
    --if oldStatus.RemainUpdate ~= status.RemainUpdate then
    --    publish(config.topics.RemainUpdate, status.RemainUpdate, 0, 1)
    --    oldStatus.RemainUpdate = status.RemainUpdate
    --end
    if oldStatus.TotalData ~= status.TotalData then
        publish(config.topics.TotalData, status.TotalData, 0, 1)
        oldStatus.TotalData = status.TotalData
    end

    timeloop = timeloop + 1
    if timeloop == 1440 then
        refresh = true
    end
end

local function ota(payload)
    require "update"
    local url = payload.host .. payload.file
    update.request(nil,url)
end

local function send(client)
    while #msgQueue > 0 do
        local msg = table.remove(msgQueue, 1)
        log.info("MQTT", "publish", msg.t, msg.p, msg.q, msg.r)
        local result = client:publish(msg.t, msg.p, msg.q, msg.r)
        if msg.c then
            msg.c(result)
        end
        if not result then
            return
        end
    end
    return true
end

local function receive(client)
    local result, data
    while true do
        result, data = client:receive(60000, "APP_SOCKET_SEND_DATA")
        -- 接收到数据
        if result then
            log.info("MQTT", "message", data.topic, data.payload)

            if data.topic == config.topics.SMS.."/Send" then
                local payload = json.decode(data.payload)
                sms.send(payload["To"],common.utf8ToGb2312(payload["Text"]) or payload["Text"])
            elseif data.topic == config.topics.Reboot then
                publish(config.topics.Online, "false", 0, 1)
                sys.restart("收到重启请求")
            elseif data.topic == config.topics.Refresh then
                log.info("MQTT","刷新状态")
                refresh = true
                sendEnv()
            elseif data.topic == config.topics.OTA  or data.topic == config.topics.preOTA then
                 local payload = json.decode(data.payload)
                 ota(payload)
            end
        else
            break
        end
    end

    return result or data == "timeout" or data == "APP_SOCKET_SEND_DATA"
end

function smsCallback(num, data, datetime)

    data = common.gb2312ToUtf8(data)
    data = string.gsub(data, "*", "\\*")
    data = string.gsub(data, "_", "\\_")
    SmsFrom(num, data, datetime)
end

-- 启动MQTT客户端任务
sys.taskInit(function()
    local retry = 0
    while true do
        if not socket.isReady() then
            retry = 0
            -- 等待网络环境准备就绪，超时时间是5分钟
            sys.waitUntil("IP_READY_IND", 300000)
        end

        if socket.isReady() then
            imei = misc.getImei()
            MNC = sim.getMnc()
            config.clientId = imei
            config.topics.Filter  = "device/" .. imei .. "/"
            config.topics.SMS     = "device/" .. imei .. "/SMS"
            config.topics.Phone   = "device/" .. imei .. "/Phone"
            config.topics.preOTA  = "device/" .. imei .. "/OTA"
            config.topics.OTA     = "device/OTA"
            config.topics.Reboot  = "device/" .. imei .. "/Reboot"
            config.topics.Status  = "device/" .. imei .. "/Status"
            config.topics.RemainUpdate = config.topics.Status .. "/RemainUpdate"
            config.topics.TotalData = config.topics.Status .. "/TotalData"
            config.topics.RemainData = config.topics.Status .. "/RemainData"
            config.topics.Online  = config.topics.Status .. "/Online"
            config.topics.Batt = config.topics.Status .. "/Batt"
            config.topics.Version = config.topics.Status .. "/Version"
            config.topics.Refresh = "device/" .. imei .. "/Refresh"

            local client = mqtt.client(config.clientId, 15, config.username, config.password,nil, {qos =1, retain=1, topic=config.topics.Online,payload="false"})

            -- 阻塞执行MQTT CONNECT动作，直至成功
            -- 如果使用ssl连接，打开client:connect("lbsmqtt.airm2m.com",1884,"tcp_ssl",{caCert="ca.crt"})，根据自己的需求配置
            -- client:connect("lbsmqtt.airm2m.com",1884,"tcp_ssl",{caCert="ca.crt"})
            if client:connect(config.server, config.port, "tcp") then
                retry = 0
                ready = true

                if MNC == "" then
                    MNC = sim.getMnc()
                end

                -- 订阅主题
                client:subscribe(config.topics.preOTA)
                client:subscribe("device/OTA")
                client:subscribe(config.topics.Reboot)
                client:subscribe(config.topics.Refresh)
                client:subscribe(config.topics.SMS.."/Send")

                -- 发布节点上线信息
                client:publish(config.topics.Online, "true",0,1)
                client:publish(config.topics.Version, _G.VERSION,0,1)

                sms.setNewSmsCb(smsCallback)
                sys.timerLoopStart(function() sendEnv() end, 60*1000)
                sendEnv()

                -- 循环处理接收和发送的数据
                while true do
                    if not receive(client) then
                        log.error("MQTT", "receive error")
                        break
                    end
                    if not send(client) then
                        log.error("MQTT", "send error")
                        break
                    end
                end

                ready = false
            else
                log.error("NET","MQTT服务器连接失败"..retry.."次")
                retry = retry + 1
            end

            -- 断开MQTT连接
            client:disconnect()
            if retry >= 5 then
                log.error("NET","MQTT服务器连接失败大于5次，关闭数据连接")
                link.shut()
                retry = 0
            end
            sys.wait(5000)
        else
            -- 飞行模式20秒，重置网络
            log.info("NET","进入飞行模式，20s后重启网络")
            net.switchFly(true)
            sys.wait(20000)
            log.info("NET","关闭飞行模式")
            net.switchFly(false)
        end
    end
end)
