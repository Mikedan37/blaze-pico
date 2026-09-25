#include "pico/stdlib.h"

// Minimal test - just blink one LED to verify firmware runs
int main() {
    stdio_init_all();
    sleep_ms(1000);  // Wait for USB
    
    const int pin = 14;  // RED_PIN
    
    gpio_init(pin);
    gpio_set_dir(pin, GPIO_OUT);
    
    // Blink LED forever - if this works, hardware is fine
    while (true) {
        gpio_put(pin, 1);
        sleep_ms(500);
        gpio_put(pin, 0);
        sleep_ms(500);
    }
}
