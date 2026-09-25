/*
    ============================================
    DIAGNOSTIC FIRMWARE - PRINTS EVERY BYTE
    ============================================
    
    This firmware prints every single byte it receives.
    Use this to debug serial communication issues.
    
    It will show:
    - Raw byte values (hex and decimal)
    - ASCII representation (if printable)
    - Newline handling
    
    Connect with: screen /dev/cu.usbmodem1101 115200
    Type anything and watch it confess.
*/

#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"

int main() {
    stdio_init_all();
    
    // Wait for USB serial to be ready
    sleep_ms(1000);
    
    printf("\n");
    printf("========================================\n");
    printf("DIAGNOSTIC MODE - BYTE SPY\n");
    printf("========================================\n");
    printf("Every byte received will be printed.\n");
    printf("Format: [hex] [dec] [char]\n");
    printf("========================================\n");
    printf("\n");
    
    uint32_t byte_count = 0;
    
    while (true) {
        int c = getchar_timeout_us(100000); // 100ms timeout
        
        if (c != PICO_ERROR_TIMEOUT) {
            byte_count++;
            
            // Print byte info
            printf("[%02X] [%3d] ", (unsigned char)c, c);
            
            // Print character if printable
            if (c >= 32 && c <= 126) {
                printf("'%c'", c);
            } else if (c == '\n') {
                printf("'\\n'");
            } else if (c == '\r') {
                printf("'\\r'");
            } else if (c == '\t') {
                printf("'\\t'");
            } else {
                printf("'?'");
            }
            
            printf(" (total: %lu)\n", byte_count);
            
            // Flush immediately so we see it
            fflush(stdout);
        }
    }
}
