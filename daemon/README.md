Turris lua daemon
=================

This is lua daemon, which reads values from ATMega8 over I2C on second (1) I2C
BUS and send it via MQTT to broker.

# Installation

```bash
scp phase2mqtt.lua root@TURRIS:/usr/bin   # where TURRIS is your Turris IP
scp phase2mqtt.conf root@TURRIS:/etc
```

**On Turris:**
```bash
chmod a+x /usr/bin/phase2mqtt
vim /etc/phase2mqtt.conf        # if you need some your settings
vim /etc/rc.local               # there is place to auto start

# packages dependecies
opkg update
opkg install luai2c luaposix luarocks lua-mosquitto

luarocks install --deps-mode=none lualogging
```

part of ``/etc/rc.local`` file on Turris before last `exit 0`:
```bash
# need on Turris 1.0 OpenWRT
export LUA_PATH="/usr/share/lua/5.1/?.lua;./?.lua;/usr/share/lua/?.lua;/usr/share/lua/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

/usr/bin/phase2mqtt.lua start
```

**On Raspbian (Debian on Raspberry Pi):**
```bash
chmod a+x /usr/bin/phase2mqtt
vim /etc/phase2mqtt.conf        # if you need some your settings
vim /etc/rc.local               # there is place to auto start

# packages dependecies
apt update
apt install lua5.1 lua-logging lua-posix

luarocks install --deps-mode=none lua-mosquitto

git clone https://github.com/LuaDist2/i2c.git
cd i2c
# I must append CFLAGS = `pkg-config --cflags lua51` line to Makefile on Debian
sudo luarocks build i2c-1.1.2-1.rockspec
```

part of ``/etc/rc.local`` file on Debian (Raspbian) before last `exit 0`:
```bash
/usr/bin/phase2mqtt.lua start
```

## Configuration

You can set MQTT topic to /some/title/{timestamp}/{phase}, when you need to
send timestamp in topic. [MQTToRRD](https://github.com/ondratu/mqttorrd) could
read only number values, but will can read timestamp from topic, to minimize
time error from network latency.