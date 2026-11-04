    ; Luke Groesbeck
    ; RCET3375
    ; I2C Part 3 Slave
    ; https://github.com/groeluke/Lab_10_I2C/tree/main/LAB_10_Part_3_I2C_Slave.X
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
Pointer         EQU 0x70        ;register the master selected (kept after STOP)
ByteCount       EQU 0x71        ;how many bytes the master has written this transaction
ReadIndex       EQU 0x72        ;which byte of a read we are sending (ADC has 2)
StatusByte      EQU 0x73        ;device status register (pointer 0x04)
StatusCopy      EQU 0x74        ;copy of SSPSTAT taken at the start of each I2C event
ReceivedByte    EQU 0x75        ;byte just received from the master
Character       EQU 0x76        ;ASCII character waiting to go to the display
NewCharacter    EQU 0x77        ;1 = Character has not been shown yet
AdcHigh         EQU 0x78        ;newest ADC sample, high byte (bits 9:8)
AdcLow          EQU 0x79        ;newest ADC sample, low byte (bits 7:0)
SendHigh        EQU 0x7A        ;frozen copy of AdcHigh used during one read
SendLow         EQU 0x7B        ;frozen copy of AdcLow used during one read
DelayHigh       EQU 0x7C        ;clock stretch delay counter, high
DelayLow        EQU 0x7D        ;clock stretch delay counter, low
	
StretchHigh     EQU 0           ;high count (0 = skip the delay completely)
StretchLow      EQU 0           ;low count
     
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
    MOVLW   0b00001000          ;only AN3 (RA3) is analog, everything else digital
    MOVWF   ANSEL               ;write it to ANSEL
    CLRF    ANSELH              ;AN8-AN13 are all digital
    ;       Bank 1
    BANKSEL TRISA               ;switch to the bank that holds the TRIS registers
    MOVLW   0b11111100          ;RA0 and RA1 are outputs (display D3 and D4), RA2 is an input
    MOVWF   TRISA               ;write it to TRISA
    MOVLW   0b11111111          ;all PORTB pins are inputs (RB0-RB5 switches, RB6/RB7 PICkit)
    MOVWF   TRISB               ;write it to TRISB
    MOVLW   0b00011000          ;RC3 and RC4 are inputs for I2C, the rest are outputs
    MOVWF   TRISC               ;write it to TRISC
    BCF     OPTION_REG,7        ;RBPU = 0 turns the PORTB weak pull-ups on
    MOVLW   0b00111111          ;pull-ups on RB0-RB5 only
    MOVWF   WPUB                ;write it to WPUB
    MOVLW   0x40                ;address 0x20 shifted left one place
    MOVWF   SSPADD              ;this PIC now answers to 0x20
    MOVLW   0b10000000          ;SMP = 1 for 100 kHz standard speed
    MOVWF   SSPSTAT             ;write it to SSPSTAT
    CLRF    SSPCON2             ;clear the I2C control bits
    MOVLW   0b10000000          ;ADFM = 1 (right justified), references are VDD and VSS
    MOVWF   ADCON1              ;write it to ADCON1
    MOVLW   249                 ;Timer2 counts 0 to 249
    MOVWF   PR2                 ;write it to PR2
    ;       Bank 0
    BANKSEL PORTA               ;back to bank 0
    CLRF    PORTA               ;display data lines D3 and D4 start low
    MOVLW   0b10000000          ;RC7 = WR idles HIGH (it is active low)
    MOVWF   PORTC               ;write it to PORTC
    MOVLW   0b00110110          ;MSSP on, clock released, I2C slave 7-bit address
    MOVWF   SSPCON              ;write it to SSPCON
    MOVLW   0b01001101          ;Timer2 on, 1:4 prescale, 1:10 postscale = 10 ms tick
    MOVWF   T2CON               ;write it to T2CON
    MOVLW   0b01001101          ;ADC clock Fosc/8, channel AN3, ADC on
    MOVWF   ADCON0              ;write it to ADCON0
    CLRF    Pointer             ;start with pointer 0x00 (switches) selected
    CLRF    ByteCount           ;no bytes received yet
    CLRF    ReadIndex           ;start at the first byte of a read
    CLRF    NewCharacter        ;nothing waiting for the display
    CLRF    AdcHigh             ;no sample yet
    CLRF    AdcLow              ;no sample yet
    MOVLW   0b00010000          ;bit 4 = no valid ADC sample yet
    MOVWF   StatusByte          ;write the starting status
    BSF     ADCON0,1            ;GO = 1 starts the first conversion

Main:
    BANKSEL PIR1                ;Bank 0
    BTFSC   PIR1,3              ;did the I2C hardware finish something (SSPIF)?
    GOTO    I2CEvent            ;yes - handle it first, it is time critical
    BTFSC   PIR1,1              ;has Timer2 counted 10 ms (TMR2IF)?
    GOTO    AdcTick             ;yes - take an ADC sample
    MOVF    NewCharacter,F      ;test NewCharacter (Z = 1 if it is 0)
    BTFSS   STATUS,2            ;skip the next line if there is nothing to show
    GOTO    ShowCharacter       ;a character is waiting - put it on the display
    GOTO    Main                ;nothing to do - check again

;I2C event handler
I2CEvent:
    BCF     PIR1,3              ;clear SSPIF
    ;       Bank 1
    BANKSEL SSPSTAT             ;SSPSTAT is in bank 1
    MOVF    SSPSTAT,W           ;read SSPSTAT
    MOVWF   StatusCopy          ;keep a copy (common RAM, readable from bank 0)
    ;       Bank 0
    BANKSEL SSPCON              ;back to bank 0 for SSPBUF and SSPCON
    BTFSC   SSPCON,7            ;WCOL: did we write SSPBUF at a bad time?
    GOTO    CollisionFound      ;yes - record it
    BTFSC   SSPCON,6            ;SSPOV: did a byte arrive before we read the last one?
    GOTO    OverflowFound       ;yes - record it
    BTFSC   StatusCopy,5        ;D/A = 1 means the last byte was data, not an address
    GOTO    DataEvent           ;so go handle data

AddressEvent:
    MOVF    SSPBUF,W            ;read the address byte (this clears BF)
    BTFSC   StatusCopy,2        ;R/W = 1 means the master wants to READ
    GOTO    ReadStart           ;so go start a read
    CLRF    ByteCount           ;write: the next byte will be the pointer
    GOTO    Main                ;wait for the next event

CollisionFound:
    BCF     SSPCON,7            ;clear WCOL
    BSF     StatusByte,1        ;status bit 1 = write collision
    GOTO    Main                ;carry on

OverflowFound:
    MOVF    SSPBUF,W            ;read SSPBUF to empty it
    BCF     SSPCON,6            ;clear SSPOV
    BSF     StatusByte,0        ;status bit 0 = receive overflow
    GOTO    Main                ;carry on

;Master is writing to us
DataEvent:
    BTFSC   StatusCopy,2        ;R/W = 1 means the master ACKed a byte we sent
    GOTO    SendNext            ;so it wants another byte
    BTFSS   StatusCopy,0        ;BF = 0 means this is the master's NACK after our last byte
    GOTO    Main                ;nothing to read - the read is finished
    MOVF    SSPBUF,W            ;read the byte from the master (this clears BF)
    MOVWF   ReceivedByte        ;keep it
    MOVF    ByteCount,F         ;test ByteCount (Z = 1 if it is 0)
    BTFSC   STATUS,2            ;ByteCount = 0 means this byte is the pointer
    GOTO    GotPointer          ;go store the pointer
    MOVF    ByteCount,W         ;load ByteCount
    XORLW   1                   ;compare with 1 (first data byte)
    BTFSS   STATUS,2            ;skip if it is the first data byte
    GOTO    ExtraData           ;second data byte or more - not allowed
    MOVF    Pointer,W           ;load the selected pointer
    XORLW   0x01                ;compare with 0x01 (the display)
    BTFSS   STATUS,2            ;skip if the pointer is the display
    GOTO    ExtraData           ;any other pointer is read-only or unsupported
    MOVF    ReceivedByte,W      ;load the character
    ANDLW   0b01111111          ;keep only the 7 ASCII bits
    MOVWF   Character           ;stage the character for the display
    MOVLW   1                   ;load a 1
    MOVWF   NewCharacter        ;tell Main a character is waiting
    INCF    ByteCount,F         ;count this data byte
    GOTO    Main                ;wait for the next event

GotPointer:
    MOVF    ReceivedByte,W      ;load the byte
    MOVWF   Pointer             ;it becomes the selected pointer (any value is accepted)
    INCF    ByteCount,F         ;count it, so the next byte is data
    GOTO    Main                ;wait for the next event

ExtraData:
    BSF     StatusByte,3        ;status bit 3 = unexpected data byte (byte is ignored)
    GOTO    Main                ;carry on

;Master is reading from us
ReadStart:
    CLRF    ReadIndex           ;this read starts at byte 0
    MOVF    AdcHigh,W           ;load the newest ADC high byte
    MOVWF   SendHigh            ;freeze it
    MOVF    AdcLow,W            ;load the newest ADC low byte
    MOVWF   SendLow             ;freeze it (both bytes now come from the same conversion)

SendNext:
    ;MOVF    Pointer,W          ;DIAGNOSTIC (step 3): remove the ; on these three lines
    ;MOVWF   SSPBUF             ;to echo the pointer back to the master,
    ;GOTO    ReleaseClock       ;then put the ; back when step 3 is done
    MOVF    Pointer,F           ;test Pointer (Z = 1 if it is 0)
    BTFSC   STATUS,2            ;pointer 0x00?
    GOTO    SendSwitches        ;yes - send the switches
    MOVF    Pointer,W           ;load the pointer
    XORLW   0x02                ;compare with 0x02
    BTFSC   STATUS,2            ;pointer 0x02?
    GOTO    SendAdc             ;yes - send the ADC
    MOVF    Pointer,W           ;load the pointer
    XORLW   0x04                ;compare with 0x04
    BTFSC   STATUS,2            ;pointer 0x04?
    GOTO    SendStatus          ;yes - send the status
    BSF     StatusByte,2        ;anything else (including write-only 0x01): status bit 2
    MOVLW   0xFF                ;send 0xFF as the "no data" value
    MOVWF   SSPBUF              ;load it into the transmit buffer
    GOTO    ReleaseClock        ;let the byte go out

SendSwitches:
    CALL    StretchDelay        ;clock stretch experiment (SCL is held LOW right now)
    MOVF    PORTB,W             ;read the six switches
    ANDLW   0b00111111          ;keep RB5:RB0 only
    MOVWF   SSPBUF              ;load it into the transmit buffer
    GOTO    ReleaseClock        ;let the byte go out

SendAdc:
    MOVF    ReadIndex,W         ;which byte is next?
    BTFSC   STATUS,2            ;ReadIndex = 0 means the high byte
    GOTO    SendHighByte        ;send the high byte
    XORLW   1                   ;compare with 1
    BTFSC   STATUS,2            ;ReadIndex = 1 means the low byte
    GOTO    SendLowByte         ;send the low byte
    BSF     StatusByte,3        ;master asked for a third byte - unexpected
    MOVLW   0xFF                ;send 0xFF
    MOVWF   SSPBUF              ;load it into the transmit buffer
    GOTO    ReleaseClock        ;let the byte go out

SendHighByte:
    MOVF    SendHigh,W          ;load the frozen high byte
    MOVWF   SSPBUF              ;load it into the transmit buffer
    INCF    ReadIndex,F         ;the low byte is next
    GOTO    ReleaseClock        ;let the byte go out

SendLowByte:
    MOVF    SendLow,W           ;load the frozen low byte
    MOVWF   SSPBUF              ;load it into the transmit buffer
    INCF    ReadIndex,F         ;count it
    GOTO    ReleaseClock        ;let the byte go out

SendStatus:
    MOVF    StatusByte,W        ;load the status
    MOVWF   SSPBUF              ;load it into the transmit buffer
    MOVLW   0b11110000          ;mask that keeps bits 7:4 and clears bits 3:0
    ANDWF   StatusByte,F        ;reading status clears the fault bits
    GOTO    ReleaseClock        ;let the byte go out

ReleaseClock:
    BSF     SSPCON,4            ;CKP = 1 releases SCL so the byte is clocked out
    GOTO    Main                ;wait for the next event

;ADC sample every 10 ms
AdcTick:
    BCF     PIR1,1              ;clear the Timer2 flag
    BTFSC   ADCON0,1            ;GO = 1 means the conversion is still running
    GOTO    Main                ;try again on the next tick
    MOVF    ADRESH,W            ;read the high result byte (bank 0)
    MOVWF   AdcHigh             ;store it
    ;       Bank 1
    BANKSEL ADRESL              ;ADRESL is in bank 1
    MOVF    ADRESL,W            ;read the low result byte
    MOVWF   AdcLow              ;store it
    ;       Bank 0
    BANKSEL ADCON0              ;back to bank 0
    BCF     StatusByte,4        ;we now have a valid sample
    BSF     ADCON0,1            ;start the next conversion
    GOTO    Main                ;back to the loop

;Put the staged character on the DLG7137
ShowCharacter:
    CLRF    NewCharacter        ;the character is being shown now
    MOVF    Character,W         ;load the character
    ANDLW   0b01111111          ;keep the 7 ASCII bits
    IORLW   0b10000000          ;keep WR (RC7) HIGH while the data settles
    MOVWF   PORTC               ;D0-D2, D5, D6 go out on PORTC (RC3/RC4 are I2C and ignore this)
    BCF     PORTA,0             ;D3 goes out on RA0, start low
    BTFSC   Character,3         ;is bit 3 of the character 1?
    BSF     PORTA,0             ;yes - make RA0 high
    BCF     PORTA,1             ;D4 goes out on RA1, start low
    BTFSC   Character,4         ;is bit 4 of the character 1?
    BSF     PORTA,1             ;yes - make RA1 high
    NOP                         ;short wait for the data lines to settle
    BCF     PORTC,7             ;WR goes LOW (write pulse starts)
    NOP                         ;hold WR low
    NOP                         ;hold WR low
    NOP                         ;hold WR low
    BSF     PORTC,7             ;WR goes HIGH (the display latches the character)
    GOTO    Main                ;back to the loop

;Clock stretch delay (about 3 us per count)
StretchDelay:
    MOVLW   StretchHigh         ;load the high count
    MOVWF   DelayHigh           ;put it in the counter
    MOVF    DelayHigh,F         ;test it (Z = 1 if it is 0)
    BTFSC   STATUS,2            ;high count 0 means no delay
    RETURN                      ;leave without waiting
    MOVLW   StretchLow          ;load the low count
    MOVWF   DelayLow            ;put it in the counter
StretchLoop:
    DECFSZ  DelayLow,F          ;count the low counter down
    GOTO    StretchLoop         ;not zero yet - keep going
    DECFSZ  DelayHigh,F         ;low counter hit zero, count the high counter down
    GOTO    StretchLoop         ;not zero yet - run the low counter another 256 times
    RETURN                      ;delay finished

    END