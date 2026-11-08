// LR2021 Modem-Firmware – Konfiguration
// Eine Firmware für beide ESP32. Die Rolle wird beim Kompilieren gewählt:
//   MODEM_ROLE_A  -> ESP32 A, LR2021 HF (Core2021-HF, 850–930 MHz + 2,4 GHz)
//   MODEM_ROLE_B  -> ESP32 B, LR2021 LF (Core2021-LF, 410–510 MHz + 2,4 GHz)
#pragma once
#include <stdint.h>

#define FW_VERSION_MAJOR 1
#define FW_VERSION_MINOR 0
#define FW_VERSION_PATCH 15

#if !defined(MODEM_ROLE_A) && !defined(MODEM_ROLE_B)
  #define MODEM_ROLE_A
#endif

// ---------------------------------------------------------------------------
// Pinbelegung laut Verdrahtungsplan (Schritt 3 / Schritt 4)
// ---------------------------------------------------------------------------
#if defined(MODEM_ROLE_A)
  #define MODEM_ROLE_CHAR   'A'
  #define MODEM_BAND_ID     1           // 1 = HF-Modul (868)
  #define PIN_LR_CS         17
  #define PIN_LR_IRQ        4           // LR2021 DIO11
  #define PIN_LR_RST        6
  #define PIN_LR_BUSY       5
  #define PIN_LR_MISO       7
  #define PIN_LR_MOSI       15
  #define PIN_LR_SCK        16
  // erlaubter Sub-GHz-Bereich des Moduls (Hz)
  #define SUBGHZ_MIN_HZ     850000000UL
  #define SUBGHZ_MAX_HZ     930000000UL
  // Startkonfiguration: Meshtastic EU_868 LongFast (nur Empfangsbereit, sendet nicht von selbst)
  #define DEF_FREQ_HZ       869525000UL
  #define DEF_BW_HZ         250000UL
  #define DEF_SF            11
  #define DEF_CR            5
  #define DEF_SYNC          0x2B
  #define DEF_POWER_DBM     14
  #define DEF_PREAMBLE      16
#else
  #define MODEM_ROLE_CHAR   'B'
  #define MODEM_BAND_ID     2           // 2 = LF-Modul (433)
  #define PIN_LR_CS         18
  #define PIN_LR_IRQ        10          // LR2021 DIO11
  #define PIN_LR_RST        7
  #define PIN_LR_BUSY       15
  #define PIN_LR_MISO       6
  #define PIN_LR_MOSI       16
  #define PIN_LR_SCK        17
  #define SUBGHZ_MIN_HZ     410000000UL
  #define SUBGHZ_MAX_HZ     510000000UL
  // Startkonfiguration: 433,875 MHz, 125 kHz, SF9 (frei änderbar)
  #define DEF_FREQ_HZ       433875000UL
  #define DEF_BW_HZ         125000UL
  #define DEF_SF            9
  #define DEF_CR            5
  #define DEF_SYNC          0x12
  #define DEF_POWER_DBM     10
  #define DEF_PREAMBLE      8
#endif

// 2,4-GHz-Bereich (beide Module)
#define HF24_MIN_HZ         2400000000UL
#define HF24_MAX_HZ         2500000000UL

// ---------------------------------------------------------------------------
// Verbindung zum Orange Pi (UART1) und USB-Konsole (UART0)
// ---------------------------------------------------------------------------
#define PIN_HOST_RX         1           // ESP32 RX  <- Pi TX
#define PIN_HOST_TX         2           // ESP32 TX  -> Pi RX
// 500000 statt 460800: Der UART des Orange Pi Zero 2W (H618) hat 24 MHz und nur ganzzahlige Teiler
// (24 MHz / 16 / n) – 460800 würde dort zu 500000 (+8,5 %) und nichts käme an.
// 500000 ist auf beiden Seiten exakt (ESP32-S3: 80 MHz / 160, H618: 24 MHz / 16 / 3).
#define HOST_BAUD           500000
#define USB_BAUD            115200

// SPI-Takt zum LR2021. 4 MHz ist auf Lochraster mit Lackdraht sicher.
#define LR_SPI_HZ           4000000

// Status-LED (WS2812 auf dem DevKitC-1, je nach Board-Version GPIO48 oder GPIO38)
#define PIN_RGB_LED         48
#define LED_BRIGHTNESS      12

// Sicherheit: Grenzwerte, die ab Werk gelten (per Befehl änderbar, im Flash speicherbar)
#define DEF_ALLOW_SUBGHZ_TX 1
#define DEF_ALLOW_24_TX     0           // 2,4 GHz Senden aus, bis Antennen dran sind
#define DEF_MAX_PWR_SUBGHZ  22
#define DEF_MAX_PWR_24      12
#define DEF_DUTY_PERMILLE   0           // 0 = keine Begrenzung, 10 = 1 % pro Stunde

#define TX_QUEUE_LEN        8
#define CAD_TIMEOUT_MS      500
#define TX_TIMEOUT_MARGIN   1.5f        // TX-Watchdog: Faktor auf die berechnete Sendezeit
