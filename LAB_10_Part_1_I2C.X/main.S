    ; Luke Groesbeck
    ; RCET3375
    ; I2C
    ; https://github.com/groeluke/Lab_10_I2C/tree/main/LAB_10_Part_1_I2C.X
    ; Linker code = -Wl,-presetVect=0000h,-pisrVect=0004h,-pcode=0008h
; PIC16F883 Configuration Bit Settings
; Assembly source line config statements

; CONFIG1
  CONFIG  FOSC = XT             ; Oscillator Selection bits (XT oscillator: Crystal/resonator on RA6/OSC2/CLKOUT and RA7/OSC1/CLKIN)
  CONFIG  WDTE = OFF            ; Watchdog Timer Enable bit (WDT disabled and can be enabled by SWDTEN bit of the WDTCON register)
  CONFIG  PWRTE = OFF           ; Power-up Timer Enable bit (PWRT disabled)
  CONFIG  MCLRE = ON            ; RE3/MCLR pin function select bit (RE3/MCLR pin function is MCLR)
  CONFIG  CP = OFF              ; Code Protection bit (Program memory code protection is disabled)
  CONFIG  CPD = OFF             ; Data Code Protection bit (Data memory code protection is disabled)
  CONFIG  BOREN = OFF           ; Brown Out Reset Selection bits (BOR disabled)
  CONFIG  IESO = OFF            ; Internal External Switchover bit (Internal/External Switchover mode is disabled)
  CONFIG  FCMEN = OFF           ; Fail-Safe Clock Monitor Enabled bit (Fail-Safe Clock Monitor is disabled)
  CONFIG  LVP = OFF             ; Low Voltage Programming Enable bit (RB3 pin has digital I/O, HV on MCLR must be used for programming)

; CONFIG2
  CONFIG  BOR4V = BOR40V        ; Brown-out Reset Selection bit (Brown-out Reset set to 4.0V)
  CONFIG  WRT = OFF             ; Flash Program Memory Self Write Enable bits (Write protection off)

; config statements should precede project file includes.
#include <xc.inc>
  SlaveAddress     EQU 0x40    ;0x20 shefited left, plus R/W = 0 (Write)
  
; Reset Vector at 0000h. Execution starts here after reset.
PSECT resetVect,class=CODE,delta=2
ResetVector: 
    GOTO Setup

; Interrupt Vector at 0004h. Execution starts here after an interrupt.
PSECT isrVect,class=CODE,delta=2
InterruptVector:
   
; Main code section starts at 0008h. User code goes here.
PSECT code,class=CODE,delta=2
 
Setup: 
    ;       Bank 3
    BANKSEL ANSEL
    CLRF    ANSEL         ;make every pin a normal digital pin
    CLRF    ANSELH        ;RB0 and RB1 can also be analog pins, so this matters
    ;       Bank 1
    BANKSEL TRISA
    BCF     TRISA,0       ;RA0 is an output (NACK indicator)
    BCF     TRISA,1       ;RA1 is an output (timer diagnostic)
    BSF     TRISC,3       ;RC3 is an input for SCL (for I2C)
    BSF     TRISC,4       ;RC$ is an input for SDA (for I2C)
    MOVLW   9
    MOVWF   SSPADD        ;100k Hz clock
    MOVLW   0b10000000
    MOVWF   SSPSTAT       ;set the Sample bit high for normal speed mode at 100k Hz
    CLRF    SSPCON2       ;set the register low so no START/STOP is running
    MOVLW   249
    MOVWF   PR2           ;Timer2 counts 250 steps
    ;       Bank 0
    BANKSEL PORTA
    CLRF    PORTA         ;both markers start LOW
    CLRF    PORTC         ;display starts blank
    MOVLW   0b00101000    
    MOVWF   SSPCON        ;set I2C on master mode and Enable the serial port pins SDA and SCL
    MOVLW   0b01001101
    MOVWF   T2CON         ;turn Timer2 ON, flag every 10ms
    
; MAIN LOOP one address probe every 10 ms
Main:
    BTFSS   PIR1,1        ;has the timer flag (TMR2IF) been set?
    GOTO    Main          ;no - keep waiting
    BCF     PIR1,1        ;yes - clear the flag

    BSF     PORTA,1       ;RA1 HIGH: a new transaction starts
    CALL    AddressProbe  ;START, address, check ACK, STOP
    BCF     PORTA,1       ;RA1 LOW: the STOP is finished
    GOTO    Main

; AddressProbe send START, the address byte, look at ACK, send STOP.
AddressProbe:
    BANKSEL PORTA
    BCF     PORTA,0       ;clear the NACK indicator

    BANKSEL SSPCON2
    BSF     SSPCON2,0     ;SEN = 1: generate a START
WaitStart:
    BTFSC   SSPCON2,0     ;SEN goes back to 0 when START is done
    GOTO    WaitStart

    BANKSEL PIR1
    BCF     PIR1,3        ;clear SSPIF (START also sets it)
    MOVLW   SlaveAddress
    MOVWF   SSPBUF        ;sending this byte starts the 9 clocks
WaitSend:
    BTFSS   PIR1,3        ;SSPIF = 1 after the 9th clock
    GOTO    WaitSend
    BCF     PIR1,3        ;clear it again

    BANKSEL SSPCON2
    BTFSS   SSPCON2,6     ;ACKSTAT: 0 = ACK, 1 = NACK
    GOTO    SendStop      ;ACK - go straight to STOP
    BANKSEL PORTA
    BSF     PORTA,0       ;NACK - turn the RA0 indicator ON
    BANKSEL SSPCON2

SendStop:
    BSF     SSPCON2,2     ;PEN = 1: generate a STOP
WaitStop:
    BTFSC   SSPCON2,2     ;PEN goes back to 0 when STOP is done
    GOTO    WaitStop

    BANKSEL PORTA         ;back to bank 0
    RETURN

    End