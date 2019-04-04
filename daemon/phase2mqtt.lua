#!/usr/bin/lua
-- Tool for reading elekctro phase meter values combinates with HDO signal from
-- I2C device, and sending these values throw MQTT.

local signal = require("posix.signal")
local unistd = require("posix.unistd")
local systime = require("posix.sys.time")
local time = require("posix.time")
local syslog = require("posix.syslog")
local getopt = require("posix.getopt")
local fcntl = require("posix.fcntl")
local stdio = require("posix.stdio")

local logging = require("logging")
local console = require("logging.console")

local i2c = require("i2c")
local mqtt = require("mosquitto")

local DEFAULTS = {
    daemon = {
        pidfile = "/var/run/phase2mqtt.pid"
    },

    logging = {
        handler = "syslog",
        file = "/var/log/phase2mqtt.log",
        level = "WARN"
    },

    mqtt = {
        hostname = "localhost",
        port = 1883,
        topic = "/phase2mqtt/{timestamp}/{phase}",
        period = 60,
        qos = 1,
        retain = true
    },

    i2c = {
        bus = 1,
        addr = 0x08
    }
}

local SYSLOG_LEVELS = {}
    SYSLOG_LEVELS[logging.DEBUG] = syslog.LOG_DEBUG
    SYSLOG_LEVELS[logging.INFO] = syslog.LOG_INFO
    SYSLOG_LEVELS[logging.WARN] = syslog.LOG_WARNING
    SYSLOG_LEVELS[logging.ERROR] = syslog.LOG_CRIT
    SYSLOG_LEVELS[logging.FATAL] = syslog.LOG_EMERG

local MQTT_LEVELS = {}
    MQTT_LEVELS[mqtt.LOG_NONE] = logging.DEBUG
    MQTT_LEVELS[mqtt.LOG_INFO] = logging.INFO
    MQTT_LEVELS[mqtt.LOG_NOTICE] = logging.INFO
    MQTT_LEVELS[mqtt.LOG_WARNING] = logging.WARN
    MQTT_LEVELS[mqtt.LOG_ERROR] = logging.ERROR
    MQTT_LEVELS[mqtt.LOG_DEBUG] = logging.DEBUG
    MQTT_LEVELS[mqtt.LOG_ALL] = logging.FATAL



local function syslog_start(ident)
    syslog.openlog(ident, syslog.LOG_PID or syslog.LOG_CONS,
                   syslog.LOG_DAEMON)
end

local function syslog_log(self, level, message)
    local priority = SYSLOG_LEVELS[level] or syslog.WARNING
    return syslog.syslog(priority, level..": "..message)
end

local function log_tb(msg)
    local info = debug.getinfo(5)
    return string.format("%s {%s() at %s:%d}", msg,
                         info.name or info.namewhat,
                         info.source, info.currentline)
end


local PidFile = {
    LOCK = {
        l_type = fcntl.F_WRLCK,      -- Exclusive lock
        l_whence = fcntl.SEEK_SET,   -- Relative to beginning of file
        l_start = 0,                 -- from 0 position
        l_len = 0
    }
}

    local __PidFile = {
        __call = function(this, path)
            local self = {}
            setmetatable(self, { __index = PidFile })
            self:__init(path)
            return self
        end
    }
    setmetatable(PidFile, __PidFile)

    function PidFile:__init(path)
        assert(io.open(path, "a+"))
        self.file = assert(io.open(path, "r+"))
        self.file:setvbuf("no")
    end

    --- Lock the file and return the state
    function PidFile:lock()
        return fcntl.fcntl(stdio.fileno(self.file),
                           fcntl.F_SETLK, PidFile.LOCK) == nil
    end

    function PidFile:write_pid()
        -- new on 34 version
        -- unistd.ftruncate(stdio.fileno(self.file), 0)
        local size = self.file:seek("end")
        self.file:seek("set")
        self.file:write(string.rep(' ', size)) -- fill with spaces

        self.file:seek("set")
        self.file:write(tostring(unistd.getpid()))
    end

    function PidFile:read_pid()
        self.file:seek("set")
        return self.file:read("*n")
    end



local Config = {}
    -- Config call
    local __Config = {
        __call = function(this, opts)
            local self = {}
            setmetatable(self, {__index=Config})
            self:__init(opts)
            return self
        end
    }
    setmetatable(Config, __Config)

    function Config:__init(opts)
        self.foreground = opts.foreground
        self:load(opts.config)
        self:set_logging()
        self:set_daemon()
        self:set_mqtt()
        self:set_i2c()
    end

    function Config:load(path)
        local fce, err = loadfile(path, "bt")
        if fce == nil then
            print(err)
            os.exit(1)
        end

        local scope = setmetatable({}, {__index = _G})
        setfenv(fce, scope)
        local ok, err = pcall(fce)
        setmetatable(scope, nil)

        if not ok then
            print(err)
            os.exit(1)
        end

        if scope.daemon == nil then
            scope.daemon = DEFAULTS.daemon
        else
            setmetatable(scope.daemon, {__index = DEFAULTS.daemon})
        end

        if scope.logging == nil then
            scope.logging = DEFAULTS.logging
        else
            setmetatable(scope.logging, {__index = DEFAULTS.logging})
        end

        if scope.mqtt == nil then
            scope.mqtt = DEFAULTS.mqtt
        else
            setmetatable(scope.mqtt, {__index = DEFAULTS.mqtt})
        end

        if scope.i2c == nil then
            scope.i2c = DEFAULTS.i2c
        else
            setmetatable(scope.i2c, {__index = DEFAULTS.i2c})
        end

        self.conf = scope
    end

    function Config:set_logging()
        local level = self.conf.logging.level
        if level == "DEBUG" then
            level = logging.DEBUG
        elseif level == "INFO" then
            level = logging.INFO
        elseif level == "ERROR" then
            level = logging.ERROR
        elseif level == "FATAL" then
            level = logging.FATAL
        else    -- defaut
            level = logging.WARN
        end

        local handler = self.conf.logging.handler
        if handler == "console" or self.foreground then
            self.log = console("%date %level: %message\n")
        elseif handler == "file" then
            self.log = logging.file(self.conf.logging.file, nil,
                                    "%date %level: %message\n")
        else    -- defaut
            syslog_start("phase2mqtt")
            self.log = logging.new(syslog_log)
        end
        self.log:setLevel(level)

        -- logger methods use log_tb to return some debug info
        self.log.debug = function(this, msg)
            return self.log:log(logging.DEBUG, log_tb, msg)
        end
        self.log.info = function(this, msg)
            return this:log(logging.INFO, log_tb, msg)
        end
        self.log.warn = function(this, msg)
            return this:log(logging.WARN, log_tb, msg)
        end
        self.log.error = function(this, msg)
            return this:log(logging.ERROR, log_tb, msg)
        end
        self.log.fatal = function(this, msg)
            return this:log(logging.FATAL, log_tb, msg)
        end
    end

    function Config:set_daemon()
        if not self.foreground then
            self.pidfile = PidFile(self.conf.daemon.pidfile)
        end
        -- TODO: change uuid guid
    end

    function Config:set_mqtt()
        self.mqtt = self.conf.mqtt
    end

    function Config:set_i2c()
        self.i2c = self.conf.i2c
    end


local Daemon = {}
    -- Daemon call
    local __Daemon = {
        __call = function(this, config)
            local self = {}
            setmetatable(self, {__index=Daemon})
            self:__init(config)
            return self
        end
    }
    setmetatable(Daemon, __Daemon)

    function Daemon:__init(config)
        self.config = config
        self.log = config.log
        self.stop = false

        signal.signal(signal.SIGTERM, function()
            self.log:info("Recieved SIGTERM")
            self.stop = true
        end)
    end

    function Daemon:run()
        self.log:info("run...")
        local connected = false

        self.client = mqtt.new()
        self.client.ON_CONNECT = function()
            self.log:info("Connected to MQTT broker.")
            connected = true
        end

        self.client.ON_DISCONNECT = function()
            self.log:info("Disconnected from MQTT broker.")
            connected = false
        end

        self.client.ON_LOG = function(level, msg)
            self.log:log(MQTT_LEVELS[level], log_tb, msg)
        end

        while not self.stop do
            if connected then
                self:read_and_send()
            elseif connected == false then
                self.log:info("Connecting to MQTT broker...")
                connected = nil
                self.client:connect(self.config.mqtt.hostname,
                                    self.config.mqtt.port)
            end

            -- TODO: mesure read_and_send function and set right timeout
            self.client:loop(900)    -- wait 900 ms for response
            local time_val = {
                tv_sec=0,
                -- shift to second
                tv_nsec = (1000000-math.fmod(systime.gettimeofday().tv_usec,
                                             1000000))*1000}
            time.nanosleep(time_val)
        end
        self.log:info("Exiting")
        if connected then
            self.client:disconnect()
        end
    end

    function Daemon:read_and_send()
        local now = systime.gettimeofday().tv_sec
        local topic = string.gsub(self.config.mqtt.topic,
                                  "{timestamp}",
                                  tostring(now))

        local result, data = i2c.read(self.config.i2c.bus,
                                      self.config.i2c.addr, 12)
        if result ~= 0 then
            self.log:error("cannot read from I2C"..i2c.error(result))
            return
        end
        local values = {
            -- AVR use little endian -> 0x0200 = 2
            nt1=data:byte(1)+data:byte(2)*256,
            nt2=data:byte(3)+data:byte(4)*256,
            nt3=data:byte(5)+data:byte(6)*256,
            vt1=data:byte(7)+data:byte(8)*256,
            vt2=data:byte(9)+data:byte(10)*256,
            vt3=data:byte(11)+data:byte(12)*256
        }
        for k, v in pairs(values) do
            local p_topic = string.gsub(topic, "{phase}", k)
            self.client:publish(p_topic, v,
                                self.config.mqtt.qos,
                                self.config.mqtt.retain)
            self.log:debug(p_topic": "..tostring(v))
        end
    end

    function Daemon:kill()
        -- try to lock
        if not self.config.pidfile:lock() then
            print("Process not running.")
        else
            print("Killing process ...")
            signal.kill(self.config.pidfile:read_pid(),
                        signal.SIGTERM)
        end
    end

    function Daemon:start()
        print("Starting process ...")
        local childpid = unistd.fork()
        if childpid == -1 then
            self.log:error("Fork failed!")
        elseif childpid == 0 then
            if self.config.pidfile:lock() then
                print("Proccess still running...")
                os.exit(1)
            end
            self.config.pidfile:write_pid()
            self:run()
        end
    end

    function Daemon:status()
        -- try to lock
        if not self.config.pidfile:lock() then
            print("Process not running.")
        else
            print("Process running ... ", self.config.pidfile:read_pid())
        end
    end


local function help(prog)
    local text = [[
usage ]]..prog..[[ [options] command

Read data from I2C, and send it to MQTT.

positional arguments:
  command           Daemon action (start|stop|restart|status)

optional arguments:
  -h                show this help message and exit
  -c <file>         Path to config file.
  -f                Run as script on foreground]]
    print(text)
end


local function main(arg)
    local opts = {
        foreground = false,
        config = "/etc/phase2mqtt.conf"
    }

    local last = 1
    for opt, opterr, i in getopt.getopt(arg, "hfc:") do
        if opt == 'h' then
            help(arg[0])
            return 0
        elseif opt == 'f' then
            opts.foreground = true
        elseif opt == 'c' then
            opts.config = opterr
        end
        last = i
    end

    local config = Config(opts)

    if opts.foreground then
        local daemon = Daemon(config)
        daemon:run()
    else
        local command = arg[last]
        if not command then
            io.stderr:write("Error: Command not set!\n")
            help(arg[0])
            return 1
        end

        local daemon = Daemon(config)
        if command == "start" then
            daemon:start()
        elseif command == "stop" then
            daemon:kill()
        elseif command == "restart" then
            daemon:kill()
            daemon:start()
        elseif command == "status" then
            daemon:status()
        else
            io.stderr:write("Error: Unknwon command `"..command.."'!\n")
            help(arg[0])
            return 1
        end
    end

    if config.conf.logging.handler == "syslog" then
        syslog.closelog()
    end
end


return main(arg)
