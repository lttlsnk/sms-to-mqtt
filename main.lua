PROJECT = "SMS_MQTT"
PRODUCT_KEY = "ASCXDDFASDFASD"
VERSION = "1.0.10"

--加载日志功能模块，并且设置日志输出等级
require "log"
require "sys"
require "net"
require "sms"
require "common"

-- 查询信号强度和基站信息
-- net.startQueryAll(60000, 60000)

-- 关闭虚拟网卡
ril.request("AT+RNDISCALL=0,1")


pmd.ldoset(2,pmd.LDO_VLCD)


require "netLed"
--netLed.setup(true,pio.P0_1,pio.P0_4)

require "mqttTask"


sys.init(0, 0)
sys.run()
