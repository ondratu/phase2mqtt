#include <Wire.h>

/*
 *  CEZ NT - low tariff, with connected HDO signal
 *  CEZ VT - high tariff, without connected HDO sinal
 *  number is one of three phases.
 */
#define NT1 0
#define NT2 1
#define NT3 2
#define VT1 3
#define VT2 4
#define VT3 5

uint16_t values[6];
uint8_t state = 0xFF;
const uint8_t I2C_ADDRESS = 0x8;

void setup() {
    // PD0 PH1
    // PD1 PH2
    // PD2 PH3
    // PD3 HDO

    DDRD &= ~(_BV(DDD3)) & ~(_BV(DDD2)) & ~(_BV(DDD1)) & ~(_BV(DDD0));  // input
    PORTD |= _BV(PD3) | _BV(PD2) | _BV(PD1) | _BV(PD0);                 // pullup

    Wire.begin(I2C_ADDRESS);        // SDA (5/PB0), SCL (2/PB2)
    Wire.onRequest(requestEvent); // register event
}

// if state is up and pin is down (button pressed), fix state and increment
// value. If state is down and pin is up, fix the state.
#define READ_VALUE(PIN, VT, NT) \
    if ((state & _BV(PIN)) && !(PIND & _BV(PIN))) { \
        state &= ~_BV(PIN); \
        if (PIND & _BV(PD3)){ \
                values[VT]++; \
            } else { \
                values[NT]++; \
            } \
    } \
    if (!(state & _BV(PIN)) && (PIND & _BV(PIN))) { \
        state |= _BV(PIN); \
    }


void loop() {
    while (true){
        READ_VALUE(PD0, VT1, NT1)
        READ_VALUE(PD1, VT2, NT2)
        READ_VALUE(PD2, VT3, NT3)
        delay(1);
    }
}

/* read and reset phase data */
void requestEvent(int numBytes) {
    // requestEvent is called from interupt vector, so no ATOMIC block is needed
    Wire.write((uint8_t*)values, 12);   // AVR use litle endian
    memset(values, 0x00, 12);           // set values to ZEOS
}
