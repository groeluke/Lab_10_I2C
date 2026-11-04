    ; Luke Groesbeck
    ; RCET3375
    ; I2C Part 3 Master
    ; https://github.com/groeluke/Lab_10_I2C/tree/main/LAB_10_Part_3_I2C.X
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

   SlaveWrite      EQU 0x40     ;slave address 0x20 with the write bit
   SlaveRead       EQU 0x41     ;slave address 0x20 with the read bit
   ValueToSend     EQU 0x70     ;pointer or character waiting to be sent
   ReadByte        EQU 0x71     ;single byte read back from the slave
   ReadHigh        EQU 0x72     ;ADC high byte read back from the slave
   ReadLow         EQU 0x73     ;ADC low byte read back from the slave
     
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
    BANKSEL ANSEL               ;switch to the bank that holds ANSEL
    CLRF    ANSEL               ;every pin is digital
    CLRF    ANSELH              ;every pin is digital
    ;       Bank 1
    BANKSEL TRISA               ;switch to the bank that holds the TRIS registers
    BCF     TRISA,0             ;RA0 is an output (NACK indicator)
    BCF     TRISA,1             ;RA1 is an output (scope trigger)
    BSF     TRISC,3             ;RC3 = SCL must be an input
    BSF     TRISC,4             ;RC4 = SDA must be an input
    MOVLW   9                   ;SSPADD = 9 gives 100 kHz at 4 MHz
    MOVWF   SSPADD              ;write it to SSPADD
    MOVLW   0b10000000          ;SMP = 1 for 100 kHz standard speed
    MOVWF   SSPSTAT             ;write it to SSPSTAT
    CLRF    SSPCON2             ;clear the I2C control bits
    MOVLW   249                 ;Timer2 counts 0 to 249
    MOVWF   PR2                 ;write it to PR2
    ;       Bank 0
    BANKSEL PORTA               ;back to bank 0
    CLRF    PORTA               ;both indicator pins start low
    MOVLW   0b00101000          ;MSSP on, I2C master mode
    MOVWF   SSPCON              ;write it to SSPCON
    MOVLW   0b01001101          ;Timer2 on, 1:4 prescale, 1:10 postscale = 10 ms tick
    MOVWF   T2CON               ;write it to T2CON

Main:
    BANKSEL PIR1                ;Bank 0
    BTFSS   PIR1,1              ;has Timer2 counted 10 ms (TMR2IF)?
    GOTO    Main                ;no - keep waiting
    BCF     PIR1,1              ;clear the flag
    BCF     PORTA,0             ;clear the NACK indicator
    BSF     PORTA,1             ;RA1 high = transaction running (scope trigger)
;uncomment ONE step at a time
    ;CALL    Step3_EchoA5       ;step 3: select 0xA5, read it back (slave echo must be on)
    ;CALL    Step3_Echo3C       ;step 3: select 0x3C, read it back
    CALL    Step4_Switches     ;step 4: select 0x00, read the six switches
    ;CALL    Step4_Status       ;step 4: select 0x04, read the status byte
    ;CALL    Step5_DisplayA     ;step 5: write 'A' to the display
    ;CALL    Step5_DisplayB     ;step 5: write 'B' to the display
    CALL    Step6_Adc          ;step 6: select 0x02, read two ADC bytes

    BCF     PORTA,1             ;RA1 low = transaction finished
    GOTO    Main                ;wait for the next tick

;Steps
Step3_EchoA5:
    MOVLW   0xA5                ;pointer value 0xA5
    CALL    SelectPointer       ;write the pointer to the slave
    CALL    ReadOneByte         ;ReadByte should now be 0xA5
    RETURN                      ;done

Step3_Echo3C:
    MOVLW   0x3C                ;pointer value 0x3C
    CALL    SelectPointer       ;write the pointer to the slave
    CALL    ReadOneByte         ;ReadByte should now be 0x3C
    RETURN                      ;done

Step4_Switches:
    MOVLW   0x00                ;pointer 0x00 = PORTB switches
    CALL    SelectPointer       ;write the pointer to the slave
    CALL    ReadOneByte         ;ReadByte = switch pattern (bits 5:0)
    RETURN                      ;done

Step4_Status:
    MOVLW   0x04                ;pointer 0x04 = device status
    CALL    SelectPointer       ;write the pointer to the slave
    CALL    ReadOneByte         ;ReadByte = status byte
    RETURN                      ;done

Step5_DisplayA:
    MOVLW   0x41                ;ASCII 'A'
    CALL    WriteCharacter      ;send pointer 0x01 and the character
    RETURN                      ;done

Step5_DisplayB:
    MOVLW   0x42                ;ASCII 'B'
    CALL    WriteCharacter      ;send pointer 0x01 and the character
    RETURN                      ;done

Step6_Adc:
    MOVLW   0x02                ;pointer 0x02 = ADC on AN2
    CALL    SelectPointer       ;write the pointer to the slave
    CALL    ReadTwoBytes        ;ReadHigh and ReadLow hold the 10-bit result
    RETURN                      ;done

;Transactions
SelectPointer:                  ;W = pointer value
    MOVWF   ValueToSend         ;keep the pointer
    CALL    Start               ;START
    MOVLW   SlaveWrite          ;0x40 = slave address + write
    CALL    Send                ;send the address
    MOVF    ValueToSend,W       ;load the pointer
    CALL    Send                ;send the pointer
    CALL    Stop                ;STOP (the slave keeps the pointer)
    RETURN                      ;done

WriteCharacter:                 ;W = ASCII character
    MOVWF   ValueToSend         ;keep the character
    CALL    Start               ;START
    MOVLW   SlaveWrite          ;0x40 = slave address + write
    CALL    Send                ;send the address
    MOVLW   0x01                ;pointer 0x01 = display
    CALL    Send                ;send the pointer
    MOVF    ValueToSend,W       ;load the character
    CALL    Send                ;send the character
    CALL    Stop                ;STOP
    RETURN                      ;done

ReadOneByte:
    CALL    Start               ;START
    MOVLW   SlaveRead           ;0x41 = slave address + read
    CALL    Send                ;send the address
    CALL    RecvNack            ;receive the byte, master NACKs (last byte)
    MOVWF   ReadByte            ;save it
    CALL    Stop                ;STOP
    RETURN                      ;done

ReadTwoBytes:
    CALL    Start               ;START
    MOVLW   SlaveRead           ;0x41 = slave address + read
    CALL    Send                ;send the address
    CALL    RecvAck             ;receive the high byte, master ACKs (more to come)
    MOVWF   ReadHigh            ;save it
    CALL    RecvNack            ;receive the low byte, master NACKs (last byte)
    MOVWF   ReadLow             ;save it
    CALL    Stop                ;STOP
    RETURN                      ;done

;I2C building blocks
Start:
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,0           ;SEN = 1 sends a START
    CALL    WaitFlag            ;wait until it is finished
    RETURN                      ;done

Stop:
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,2           ;PEN = 1 sends a STOP
    CALL    WaitFlag            ;wait until it is finished
    RETURN                      ;done

Send:                           ;W = byte to send
    BANKSEL SSPBUF              ;Bank 0
    MOVWF   SSPBUF              ;sending starts when SSPBUF is written
    CALL    WaitFlag            ;wait until the byte and the ACK slot are done
    BANKSEL SSPCON2             ;Bank 1
    BTFSS   SSPCON2,6           ;ACKSTAT = 0 means the slave ACKed
    RETURN                      ;it ACKed - nothing more to do
    BANKSEL PORTA               ;Bank 0
    BSF     PORTA,0             ;slave NACKed - RA0 goes high
    RETURN                      ;done

RecvNack:                       ;returns the byte in W
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,5           ;ACKDT = 1 means we will send a NACK
    GOTO    Receive             ;share the receive code below

RecvAck:                        ;returns the byte in W
    BANKSEL SSPCON2             ;Bank 1
    BCF     SSPCON2,5           ;ACKDT = 0 means we will send an ACK

Receive:
    BSF     SSPCON2,3           ;RCEN = 1 starts receiving one byte
    CALL    WaitFlag            ;wait until the byte has arrived
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,4           ;ACKEN = 1 sends the ACK or NACK
    CALL    WaitFlag            ;wait until it has been sent
    BANKSEL SSPBUF              ;Bank 0
    MOVF    SSPBUF,W            ;W = the byte we received
    RETURN                      ;done

WaitFlag:                       ;waits for SSPIF, keeps W unchanged
    BANKSEL PIR1                ;Bank 0
WaitLoop:
    BTFSS   PIR1,3              ;has the I2C hardware finished (SSPIF)?
    GOTO    WaitLoop            ;no - keep waiting
    BCF     PIR1,3              ;clear SSPIF
    RETURN                      ;done

    END