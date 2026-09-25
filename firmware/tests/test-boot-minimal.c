#include "pico/stdlib.h"

// ABSOLUTE MINIMAL TEST - just blink one LED
// If this doesn't work, hardware issue
int main() {
    // Initialize clocks/USB
    stdio_init_all();
    
    // Wait for USB (optional - LEDs should work without USB)
    sleep_ms(100);
    
    // Test GPIO 14 (RED_PIN)
    const int pin = 14;
    
    gpio_init(pin);
    gpio_set_dir(pin, GPIO_OUT);
    gpio_disable_pulls(pin);
    
    // Blink LED forever - if this works, hardware is fine
    while (true) {
        gpio_put(pin, 1);  // ON
        sleep_ms(500);
        gpio_put(pin, 0);  // OFF
        sleep_ms(500);
    }
}
