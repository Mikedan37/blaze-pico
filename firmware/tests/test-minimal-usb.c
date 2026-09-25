#include "pico/stdlib.h"

// Minimal test - SDK init + blink one LED
// This proves firmware runs AND USB works
int main() {
    stdio_init_all();
    
    const int pin = 14;  // RED_PIN
    
    gpio_init(pin);
    gpio_set_dir(pin, GPIO_OUT);
    
    // Blink LED forever - if this works, firmware is fine
    while (true) {
        gpio_put(pin, 1);
        sleep_ms(500);
        gpio_put(pin, 0);
        sleep_ms(500);
    }
}
