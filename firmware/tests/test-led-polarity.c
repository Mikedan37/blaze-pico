/*
    CAVEMAN MODE LED TEST
    Tests LED polarity - no protocol, no daemon, no telemetry
    Just GPIO physics
*/

#include "pico/stdlib.h"

#define RED_PIN 14
#define GREEN_PIN 15
#define YELLOW_PIN 16
#define BLUE_PIN 17
#define MULTI_RED_PIN 24
#define MULTI_GREEN_PIN 25
#define MULTI_BLUE_PIN 26

int main() {
    stdio_init_all();
    
    // Initialize GPIO
    gpio_init(RED_PIN);
    gpio_set_dir(RED_PIN, GPIO_OUT);
    
    gpio_init(GREEN_PIN);
    gpio_set_dir(GREEN_PIN, GPIO_OUT);
    
    gpio_init(YELLOW_PIN);
    gpio_set_dir(YELLOW_PIN, GPIO_OUT);
    
    gpio_init(BLUE_PIN);
    gpio_set_dir(BLUE_PIN, GPIO_OUT);
    
    gpio_init(MULTI_RED_PIN);
    gpio_set_dir(MULTI_RED_PIN, GPIO_OUT);
    
    gpio_init(MULTI_GREEN_PIN);
    gpio_set_dir(MULTI_GREEN_PIN, GPIO_OUT);
    
    gpio_init(MULTI_BLUE_PIN);
    gpio_set_dir(MULTI_BLUE_PIN, GPIO_OUT);
    
    // Test HIGH = ON (common anode)
    gpio_put(RED_PIN, 1);
    gpio_put(GREEN_PIN, 1);
    gpio_put(YELLOW_PIN, 1);
    gpio_put(BLUE_PIN, 1);
    gpio_put(MULTI_RED_PIN, 1);
    gpio_put(MULTI_GREEN_PIN, 1);
    gpio_put(MULTI_BLUE_PIN, 1);
    
    // Wait 5 seconds
    sleep_ms(5000);
    
    // Test LOW = ON (common cathode)
    gpio_put(RED_PIN, 0);
    gpio_put(GREEN_PIN, 0);
    gpio_put(YELLOW_PIN, 0);
    gpio_put(BLUE_PIN, 0);
    gpio_put(MULTI_RED_PIN, 0);
    gpio_put(MULTI_GREEN_PIN, 0);
    gpio_put(MULTI_BLUE_PIN, 0);
    
    // Wait 5 seconds
    sleep_ms(5000);
    
    // Turn off
    gpio_put(RED_PIN, 0);
    gpio_put(GREEN_PIN, 0);
    gpio_put(YELLOW_PIN, 0);
    gpio_put(BLUE_PIN, 0);
    gpio_put(MULTI_RED_PIN, 0);
    gpio_put(MULTI_GREEN_PIN, 0);
    gpio_put(MULTI_BLUE_PIN, 0);
    
    while(1) {}
}
