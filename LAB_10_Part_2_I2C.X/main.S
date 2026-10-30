    ; Luke Groesbeck
    ; RCET3375
    ; I2C
    ; https://github.com/groeluke/Lab_10_I2C/tree/main/LAB_10_Part_2_I2C.X
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
;ADS1115 address bytes (7-bit address shifted left, R/W = 0)
   AddressGND     EQU 0x90     ;ADDR pin on GND  0x48
   AddressVDD     EQU 0x92     ;ADDR pin on VDD  0x49
   AddressSDA     EQU 0x94     ;ADDR pin on SDA  0x4A
   AddressSCL     EQU 0x96     ;ADDR pin on SCL  0x4B

;The address used for steps 2 to 5. This is ment for after Part 1
   AddressWrite   EQU AddressGND        ;address + write bit
   AddressRead    EQU AddressGND + 1    ;address + read bit

   RegisterPointer EQU 0x70    ;which ADS1115 register to select (0x00 to 0x03)
   WriteHighByte   EQU 0x71    ;high byte to write
   WriteLowByte    EQU 0x72    ;low byte to write
   ReadHighByte    EQU 0x73    ;high byte we read back
   ReadLowByte     EQU 0x74    ;low byte we read back
     
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
    CLRF    ANSEL              ;make every pin a normal digital pin
    CLRF    ANSELH             ;RB0 and RB1 can also be analog pins, so this matters
    ;       Bank 1
    BANKSEL TRISA
    BCF     TRISA,0            ;RA0 is an output (NACK indicator)
    BCF     TRISA,1            ;RA1 is an output (timer diagnostic)
    BSF     TRISC,3            ;RC3 is an input for SCL (for I2C)
    BSF     TRISC,4            ;RC4 is an input for SDA (for I2C)
    MOVLW   9
    MOVWF   SSPADD             ;100k Hz clock
    MOVLW   0b10000000
    MOVWF   SSPSTAT            ;set the Sample bit high for normal speed mode at 100k Hz
    CLRF    SSPCON2            ;set the register low so no START/STOP is running
    MOVLW   255
    MOVWF   PR2                ;Timer2 counts 250 steps
    ;       Bank 0
    BANKSEL PORTA
    CLRF    PORTA              ;both markers start LOW
    CLRF    PORTC              ;starts blank
    MOVLW   0b00101000    
    MOVWF   SSPCON             ;set I2C on master mode and Enable the serial port pins SDA and SCL
    MOVLW   0b01001101
    MOVWF   T2CON              ;turn Timer2 ON, flag every 10ms

; Main picks one step by removing the comment ;.
;Step 1, 2, 3 and 5 run once, then the PIC sits in the Done loop until reprogram
Main:
    ;CALL    Step1_Probe       ;step 1: probe the four addresses
    ;CALL    Step2_ReadConfig  ;step 2: read the Config register
    ;CALL    Step3_WriteConfig ;step 3: write Config, read it back
    CALL    Step4_Poll        ;step 4: configure once, then read forever
    CALL    Step5_AlertSetup  ;step 5: turn on ALERT/RDY pulses
Done:
    GOTO    Done               ;do nothing

; STEP 1 - probe all four addresses, one after another.
; RA1 goes HIGH during each probe. RA0 shows that probe's result.
Step1_Probe:
    MOVLW   AddressGND
    CALL    ProbeOne           ;try the GND address (0x48)
    MOVLW   AddressVDD
    CALL    ProbeOne           ;try the VDD address (0x49)
    MOVLW   AddressSDA
    CALL    ProbeOne           ;try the SDA address (0x4A)
    MOVLW   AddressSCL
    CALL    ProbeOne           ;try the SCL address (0x4B)
    RETURN

ProbeOne:                      ;in: W = address byte
    BSF     PORTA,1            ;RA1 HIGH: probe starts (W is not changed)
    CALL    I2C_Start          ;(W is not changed by START either)
    CALL    SendByte           ;send the address in W, RA0 = result
    CALL    I2C_Stop
    BCF     PORTA,1            ;RA1 LOW: probe finished
    RETURN

; STEP 2 - read the Config register. A new ADS1115 shows 0x8583.
; The answer is in ReadHighByte and ReadLowByte.
Step2_ReadConfig:
    MOVLW   0x01
    MOVWF   RegisterPointer    ;0x01 = Config register
    CALL    SetPointer         ;START, ADDR+W, 0x01, STOP
    CALL    ReadTwoBytes       ;START, ADDR+R, high, low, STOP
    RETURN

; STEP 3 - write Config, then read it back.
; AIN0 vs GND, +/-6.144 V, continuous, 128 SPS, comparator off.
Step3_WriteConfig:
    MOVLW   0x01
    MOVWF   RegisterPointer    ;Config register
    MOVLW   0b01000000
    MOVWF   WriteHighByte      ;Config high byte
    MOVLW   0b10000011
    MOVWF   WriteLowByte       ;Config low byte
    CALL    WriteRegister      ;write it
    CALL    ReadTwoBytes       ;pointer is still Config, so just read
    RETURN

; STEP 4 - configure once, then read the conversion every timer tick.
; The answer is in ReadHighByte and ReadLowByte (signed 16-bit).
Step4_Poll:
   MOVLW   0x02
    MOVWF   RegisterPointer    ;Lo threshold register
    CLRF    WriteHighByte
    CLRF    WriteLowByte       ;Lo = 0x0000
    CALL    WriteRegister
    MOVLW   0x03
    MOVWF   RegisterPointer    ;Hi threshold register
    MOVLW   0b10000000
    MOVWF   WriteHighByte
    CLRF    WriteLowByte       ;Hi = 0x8000
    CALL    WriteRegister
    MOVLW   0x01
    MOVWF   RegisterPointer    ;Config register
    MOVLW   0b01000000
    MOVWF   WriteHighByte
    MOVLW   0b10000000
    MOVWF   WriteLowByte       ;same Config, comparator queue = 00
    CALL    WriteRegiste
PollLoop:
    BTFSS   PIR1,1             ;timer flag?
    GOTO    PollLoop
    BCF     PIR1,1             ;clear it
    BSF     PORTA,1            ;RA1 HIGH: a cycle starts
    CLRF    RegisterPointer    ;0x00 = Conversion register
    CALL    SetPointer         ;START, ADDR+W, 0x00, STOP
    CALL    ReadTwoBytes       ;START, ADDR+R, high, low, STOP
    BCF     PORTA,1            ;RA1 LOW: cycle finished
    GOTO    PollLoop

; STEP 5 - turn on the ALERT/RDY pulses, once.
Step5_AlertSetup:
    MOVLW   0x02
    MOVWF   RegisterPointer    ;Lo threshold register
    CLRF    WriteHighByte
    CLRF    WriteLowByte       ;Lo = 0x0000
    CALL    WriteRegister

    MOVLW   0x03
    MOVWF   RegisterPointer    ;Hi threshold register
    MOVLW   0b10000000
    MOVWF   WriteHighByte
    CLRF    WriteLowByte       ;Hi = 0x8000
    CALL    WriteRegister

    MOVLW   0x01
    MOVWF   RegisterPointer    ;Config register
    MOVLW   0b01000000
    MOVWF   WriteHighByte
    MOVLW   0b10000000
    MOVWF   WriteLowByte       ;same Config, comparator queue = 00
    CALL    WriteRegister
    RETURN

; SetPointer - START, ADDR+W, register pointer, STOP.
; in: RegisterPointer.  If RA0 is HIGH (NACK), it skips ahead to STOP.
SetPointer:
    CALL    I2C_Start
    MOVLW   AddressWrite
    CALL    SendByte           ;address + write
    BTFSC   PORTA,0            ;NACK?
    GOTO    SetPointerDone     ;yes - stop sending
    MOVF    RegisterPointer,W
    CALL    SendByte           ;the register pointer
SetPointerDone:
    CALL    I2C_Stop
    RETURN

; WriteRegister - START, ADDR+W, pointer, high byte, low byte, STOP.
; in: RegisterPointer, WriteHighByte, WriteLowByte
; Stops sending at the first NACK (RA0 HIGH).
WriteRegister:
    CALL    I2C_Start
    MOVLW   AddressWrite
    CALL    SendByte           ;address + write
    BTFSC   PORTA,0
    GOTO    WriteRegisterDone
    MOVF    RegisterPointer,W
    CALL    SendByte           ;register pointer
    BTFSC   PORTA,0
    GOTO    WriteRegisterDone
    MOVF    WriteHighByte,W
    CALL    SendByte           ;high byte
    BTFSC   PORTA,0
    GOTO    WriteRegisterDone
    MOVF    WriteLowByte,W
    CALL    SendByte           ;low byte
WriteRegisterDone:
    CALL    I2C_Stop
    RETURN
    
; ReadTwoBytes - START, ADDR+R, high (PIC ACK), low (PIC NACK), STOP.
; out: ReadHighByte, ReadLowByte
ReadTwoBytes:
    CALL    I2C_Start
    MOVLW   AddressRead
    CALL    SendByte           ;address + read
    BTFSC   PORTA,0            ;NACK?
    GOTO    ReadTwoBytesDone   ;yes means nothing to read
    CALL    ReceiveByteAck     ;high byte, the PIC sends ACK
    MOVWF   ReadHighByte
    CALL    ReceiveByteNack    ;low byte, the PIC sends NACK
    MOVWF   ReadLowByte
ReadTwoBytesDone:
    CALL    I2C_Stop
    RETURN

; BASIC I2C ROUTINES (each returns in bank 0)
; Each one clears SSPIF, starts the job, then waits for SSPIF = 1.
I2C_Start:
    BANKSEL PIR1
    BCF     PIR1,3             ;clear SSPIF
    BANKSEL SSPCON2
    BSF     SSPCON2,0          ;generate a START
    BANKSEL PIR1
    CALL    WaitSSPIF
    RETURN

I2C_Stop:
    BANKSEL PIR1
    BCF     PIR1,3             ;clear SSPIF
    BANKSEL SSPCON2
    BSF     SSPCON2,2          ;generate a STOP
    BANKSEL PIR1
    CALL    WaitSSPIF
    RETURN

; SendByte - sends the byte in W and checks the slave's reply.
; RA0 HIGH = NACK, RA0 LOW = ACK.
SendByte:
    BANKSEL PIR1
    BCF     PIR1,3             ;clear SSPIF
    MOVWF   SSPBUF             ;send the byte
    CALL    WaitSSPIF          ;wait for all 9 clocks
    BANKSEL SSPCON2
    BTFSS   SSPCON2,6          ;ACKSTAT: 0 = ACK, 1 = NACK
    GOTO    SendByteAck
    BANKSEL PORTA
    BSF     PORTA,0            ;RA0 ON = NACK
    RETURN
SendByteAck:
    BANKSEL PORTA
    BCF     PORTA,0            ;RA0 OFF = ACK
    RETURN

; ReceiveByteAck / ReceiveByteNack - receive one byte, then send
; ACK (Ack) or NACK (Nack). The received byte comes back in W.
ReceiveByteAck:
    BANKSEL SSPCON2
    BCF     SSPCON2,5          ;ACKDT = 0: we will send ACK
    GOTO    ReceiveByte
ReceiveByteNack:
    BANKSEL SSPCON2
    BSF     SSPCON2,5          ;ACKDT = 1: we will send NACK
ReceiveByte:
    BANKSEL PIR1
    BCF     PIR1,3             ;clear SSPIF
    BANKSEL SSPCON2
    BSF     SSPCON2,3          ;receive 8 bits
    BANKSEL PIR1
    CALL    WaitSSPIF          ;wait until the byte is in
    MOVF    SSPBUF,W           ;W = the received byte (nothing below changes W)
    BCF     PIR1,3             ;clear SSPIF again
    BANKSEL SSPCON2
    BSF     SSPCON2,4          ;send the ACK or NACK now
    BANKSEL PIR1
    CALL    WaitSSPIF          ;wait until it is sent
    RETURN                     ;W = the received byte

WaitSSPIF:                     ;wait until SSPIF = 1 (needs bank 0)
    BTFSS   PIR1,3
    GOTO    WaitSSPIF
    RETURN

    End