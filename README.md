Electric phase meter
====================

This is set of tools which read electric meter and sent it to MQTT.


## Tree
* pm_atmega8 - source code of I2C slave which reads impulses from SDM120 and
  send it to master based on ATMega8 MCU.
* daemon - lua daemon to send values from I2C to MQTT
