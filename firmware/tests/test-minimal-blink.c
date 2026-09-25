#include "pico/stdlib.h"

// Minimal blink test - NO USB, NO stdio_init_all()
// This proves if firmware executes at all
int main() {
    const int pin = 14;  // GP14 (external LED you know works)
    
    gpio_init(pin);
    gpio_set_dir(pin, GPIO_OUT);
    
    // Blink forever - if this works, firmware is running
    while (true) {
        gpio_put(pin, 1);
        sleep_ms(300);
        gpio_put(pin, 0);
        sleep_ms(300);
    }
}
