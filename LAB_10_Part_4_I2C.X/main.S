    ; Luke Groesbeck
    ; RCET3375
    ; I2C Part 4 Master
    ; https://github.com/groeluke/Lab_10_I2C/tree/main/LAB_10_Part_4_I2C.X
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

   ; ---------------- Variables (common RAM 0x70-0x7F) ----------------
RxState         EQU 0x70        ;parser state: 0 start, 1 command, 2 length, 3 payload, 4 request ready
Command         EQU 0x71        ;command byte of the current request (49, 50, 57 or 52)
PayloadLength   EQU 0x72        ;payload length the host declared
PayloadCount    EQU 0x73        ;payload bytes received so far
RequestError    EQU 0x74        ;bridge error detail EE (0 = none, 1 length, 2 command, 3 address)
I2CError        EQU 0x75        ;I2C error detail SS (0 = none, 1 NACK, 2 timeout, 3 bus low, 4 SCL low)
ReplyLength     EQU 0x76        ;payload length of the reply
ReceivedByte    EQU 0x77        ;byte just read from the UART
LoopCount       EQU 0x78        ;loop counter for buffers
AddressByte     EQU 0x79        ;7-bit address shifted left, ready to send
TimeoutHigh     EQU 0x7A        ;I2C timeout counter, high
TimeoutLow      EQU 0x7B        ;I2C timeout counter, low
ErrorCategory   EQU 0x7C        ;error packet category (01, 02, 04, 05)
ErrorDetail     EQU 0x7D        ;error packet detail

; ---------------- Buffers (bank 0, reached with FSR/INDF) ----------------
RxBuffer        EQU 0x20        ;request payload, 24 bytes (0x20-0x37)
ReplyBuffer     EQU 0x38        ;reply payload, 24 bytes (0x38-0x4F)

TimeoutStart    EQU 50          ;I2C timeout is about 51 ms (256 x 50 x 4 us)

; Reset Vector at 0000h. Execution starts here after reset.
PSECT resetVect,class=CODE,delta=2
ResetVector:
    GOTO Setup                  ;jump to Setup when the PIC resets

; Interrupt Vector at 0004h. No interrupts are used.
PSECT isrVect,class=CODE,delta=2
InterruptVector:
    GOTO $                      ;trap here if an interrupt ever fires

; Main code section starts at 0008h.
PSECT code,class=CODE,delta=2

Setup:
    ;       Bank 3
    BANKSEL ANSEL               ;switch to the bank that holds ANSEL
    CLRF    ANSEL               ;every pin is digital
    CLRF    ANSELH              ;every pin is digital
    CLRF    BAUDCTL             ;BRG16 = 0, 8-bit baud rate generator
    ;       Bank 1
    BANKSEL TXSTA               ;switch to the bank that holds TXSTA
    MOVLW   0b00100100          ;TXEN = 1, asynchronous, BRGH = 1, 8-bit
    MOVWF   TXSTA               ;write it to TXSTA
    MOVLW   25                  ;9600 baud at 4 MHz
    MOVWF   SPBRG               ;write it to SPBRG
    BSF     TRISC,6             ;RC6 = TX (bit set as the data sheet requires)
    BSF     TRISC,7             ;RC7 = RX (bit set as the data sheet requires)
    BSF     TRISC,3             ;RC3 = SCL must be an input
    BSF     TRISC,4             ;RC4 = SDA must be an input
    BCF     TRISA,1             ;RA1 is an output (high while the bridge is using the I2C bus)
    MOVLW   9                   ;SSPADD = 9 gives 100 kHz at 4 MHz
    MOVWF   SSPADD              ;write it to SSPADD
    MOVLW   0b10000000          ;SMP = 1 for 100 kHz
    MOVWF   SSPSTAT             ;write it to SSPSTAT
    CLRF    SSPCON2             ;clear the I2C control bits
    ;       Bank 0
    BANKSEL RCSTA               ;back to bank 0
    MOVLW   0b10010000          ;SPEN = 1 serial port on, CREN = 1 receiver on
    MOVWF   RCSTA               ;write it to RCSTA
    MOVLW   0b00101000          ;MSSP on, I2C master mode
    MOVWF   SSPCON              ;write it to SSPCON
    CLRF    PORTA               ;RA1 starts low
    CLRF    RxState             ;parser waits for a start byte
    CLRF    I2CError            ;no I2C error
    CLRF    RequestError        ;no request error

Main:
    CALL    ServiceRx           ;handle one received byte or UART error
    MOVF    RxState,W           ;load the parser state
    XORLW   4                   ;state 4 means a full request is ready
    BTFSC   STATUS,2            ;skip if the request is not ready
    CALL    ProcessRequest      ;carry out the request and send the reply
    GOTO    Main                ;repeat forever

; ---------------- UART receive ----------------
ServiceRx:
    BANKSEL RCSTA               ;Bank 0
    BTFSC   RCSTA,1             ;OERR = 1 means the receiver overran
    GOTO    RxOverrun           ;handle the overrun
    BTFSS   PIR1,5              ;RCIF = 1 means a byte is waiting
    RETURN                      ;nothing arrived
    BTFSC   RCSTA,2             ;FERR = 1 means this byte has a framing error
    GOTO    RxFraming           ;handle the framing error
    MOVF    RCREG,W             ;read the byte (this clears RCIF)
    MOVWF   ReceivedByte        ;keep it
    CALL    ParseByte           ;run the parser on it
    RETURN                      ;done

RxOverrun:
    BCF     RCSTA,4             ;CREN off clears OERR
    BSF     RCSTA,4             ;CREN on restarts the receiver
RxFlush:
    BTFSS   PIR1,5              ;is there an old byte in the FIFO?
    GOTO    RxOverrunDone       ;no - the FIFO is empty
    MOVF    RCREG,W             ;read it and throw it away
    GOTO    RxFlush             ;check for more
RxOverrunDone:
    CLRF    RxState             ;the partial packet is discarded
    MOVLW   0x02                ;category 02 = UART overrun
    MOVWF   ErrorCategory       ;set the category
    CLRF    ErrorDetail         ;detail is 00
    CALL    SendError           ;send 24 45 02 02 00
    RETURN                      ;done

RxFraming:
    MOVF    RCREG,W             ;read the bad byte and throw it away (clears FERR)
    CLRF    RxState             ;the partial packet is discarded
    MOVLW   0x01                ;category 01 = UART framing error
    MOVWF   ErrorCategory       ;set the category
    CLRF    ErrorDetail         ;detail is 00
    CALL    SendError           ;send 24 45 02 01 00
    RETURN                      ;done

; ---------------- Packet parser (one byte per call) ----------------
ParseByte:
    MOVF    RxState,F           ;test the state (Z = 1 if it is 0)
    BTFSC   STATUS,2            ;state 0?
    GOTO    StateStart          ;yes - waiting for 0x24
    MOVF    RxState,W           ;load the state
    XORLW   1                   ;compare with 1
    BTFSC   STATUS,2            ;state 1?
    GOTO    StateCommand        ;yes - this byte is the command
    MOVF    RxState,W           ;load the state
    XORLW   2                   ;compare with 2
    BTFSC   STATUS,2            ;state 2?
    GOTO    StateLength         ;yes - this byte is the length
    GOTO    StatePayload        ;otherwise state 3 - payload bytes

StateStart:
    MOVF    ReceivedByte,W      ;load the byte
    XORLW   0x24                ;is it the start byte 0x24?
    BTFSS   STATUS,2            ;skip if yes
    RETURN                      ;no - ignore it and keep waiting
    MOVLW   1                   ;load a 1
    MOVWF   RxState             ;next byte is the command
    RETURN                      ;done

StateCommand:
    MOVF    ReceivedByte,W      ;load the command byte
    MOVWF   Command             ;remember it
    CLRF    RequestError        ;no request error so far
    XORLW   0x49                ;identity?
    BTFSC   STATUS,2            ;yes?
    GOTO    CommandKnown        ;known command
    MOVF    Command,W           ;load the command
    XORLW   0x50                ;probe?
    BTFSC   STATUS,2            ;yes?
    GOTO    CommandKnown        ;known command
    MOVF    Command,W           ;load the command
    XORLW   0x57                ;write?
    BTFSC   STATUS,2            ;yes?
    GOTO    CommandKnown        ;known command
    MOVF    Command,W           ;load the command
    XORLW   0x52                ;read?
    BTFSC   STATUS,2            ;yes?
    GOTO    CommandKnown        ;known command
    MOVLW   2                   ;none matched
    MOVWF   RequestError        ;bridge error 02 = unknown command
CommandKnown:
    MOVLW   2                   ;load a 2
    MOVWF   RxState             ;next byte is the length
    RETURN                      ;done

StateLength:
    MOVF    ReceivedByte,W      ;load the length byte
    MOVWF   PayloadLength       ;remember it
    CLRF    PayloadCount        ;no payload bytes yet
    MOVF    RequestError,F      ;is there already an error (unknown command)?
    BTFSS   STATUS,2            ;skip if there is none
    GOTO    CheckPayload        ;keep that error
    MOVLW   25                  ;load 25
    SUBWF   ReceivedByte,W      ;W = length - 25, C = 1 if length >= 25
    BTFSS   STATUS,0            ;skip if length is 25 or more
    GOTO    CheckPayload        ;length is 24 or less - fine
    MOVLW   1                   ;too long
    MOVWF   RequestError        ;bridge error 01 = invalid length
CheckPayload:
    MOVF    PayloadLength,F     ;is the length 0?
    BTFSC   STATUS,2            ;yes?
    GOTO    RequestDone         ;no payload - the request is complete
    MOVLW   3                   ;load a 3
    MOVWF   RxState             ;next bytes are payload
    RETURN                      ;done

StatePayload:
    MOVF    RequestError,F      ;is the request already bad?
    BTFSS   STATUS,2            ;skip if it is fine
    GOTO    CountByte           ;bad - count the byte but do not store it
    MOVF    PayloadCount,W      ;load the index
    ADDLW   RxBuffer            ;add the buffer start address
    MOVWF   FSR                 ;point FSR at the slot
    MOVF    ReceivedByte,W      ;load the byte
    MOVWF   INDF                ;store it in the buffer
CountByte:
    INCF    PayloadCount,F      ;one more payload byte
    MOVF    PayloadCount,W      ;load the count
    XORWF   PayloadLength,W     ;compare with the declared length
    BTFSS   STATUS,2            ;skip if all bytes have arrived
    RETURN                      ;more to come
RequestDone:
    MOVLW   4                   ;load a 4
    MOVWF   RxState             ;the request is ready
    RETURN                      ;done

; ---------------- Carry out a request ----------------
ProcessRequest:
    CLRF    RxState             ;ready for the next packet
    CLRF    I2CError            ;no I2C error yet
    MOVF    RequestError,F      ;did the parser find a problem?
    BTFSS   STATUS,2            ;skip if not
    GOTO    BridgeError         ;send the bridge error packet
    MOVF    Command,W           ;load the command
    XORLW   0x49                ;identity?
    BTFSC   STATUS,2            ;yes?
    GOTO    DoIdentity          ;go do it
    MOVF    Command,W           ;load the command
    XORLW   0x50                ;probe?
    BTFSC   STATUS,2            ;yes?
    GOTO    DoProbe             ;go do it
    MOVF    Command,W           ;load the command
    XORLW   0x57                ;write?
    BTFSC   STATUS,2            ;yes?
    GOTO    DoWrite             ;go do it
    GOTO    DoRead              ;only read (0x52) is left

BadLength:
    MOVLW   1                   ;bridge error 01
    MOVWF   RequestError        ;invalid length or count
BridgeError:
    MOVF    RequestError,W      ;load the error detail
    MOVWF   ErrorDetail         ;set the detail
    MOVLW   0x05                ;category 05 = bridge request error
    MOVWF   ErrorCategory       ;set the category
    GOTO    SendError           ;send the error packet and return to Main

DoIdentity:
    MOVF    PayloadLength,F     ;identity must have no payload
    BTFSS   STATUS,2            ;skip if the length is 0
    GOTO    BadLength           ;otherwise reject it
    MOVLW   0x33                ;first identity byte
    MOVWF   ReplyBuffer         ;put it in the reply
    MOVLW   0x75                ;second identity byte
    MOVWF   ReplyBuffer+1       ;put it in the reply
    MOVLW   2                   ;reply payload is 2 bytes
    MOVWF   ReplyLength         ;set the length
    GOTO    SendReply           ;send 24 49 02 33 75

DoProbe:
    MOVF    PayloadLength,W     ;load the length
    XORLW   1                   ;probe must have exactly 1 byte
    BTFSS   STATUS,2            ;skip if it does
    GOTO    BadLength           ;otherwise reject it
    CALL    CheckAddress        ;is the address 08-77?
    MOVF    RequestError,F      ;did the check fail?
    BTFSS   STATUS,2            ;skip if it passed
    GOTO    BridgeError         ;invalid address
    CLRF    ReplyBuffer         ;reply payload is 00
    MOVLW   1                   ;reply payload is 1 byte
    MOVWF   ReplyLength         ;set the length
    BANKSEL PORTA               ;Bank 0
    BSF     PORTA,1             ;RA1 high = I2C bus in use
    CALL    MakeAddress         ;address shifted left, write bit 0
    CALL    I2CStart            ;START
    MOVF    AddressByte,W       ;load the address byte
    CALL    I2CSend             ;send it (a NACK is recorded)
    CALL    I2CStop             ;STOP
    GOTO    FinishI2C           ;send the reply or the I2C error

DoWrite:
    MOVF    PayloadLength,W     ;load the length
    SUBLW   1                   ;C = 1 if length <= 1 (no data bytes)
    BTFSC   STATUS,0            ;skip if there is data
    GOTO    BadLength           ;address-only write is rejected
    CALL    CheckAddress        ;is the address 08-77?
    MOVF    RequestError,F      ;did the check fail?
    BTFSS   STATUS,2            ;skip if it passed
    GOTO    BridgeError         ;invalid address
    CLRF    ReplyBuffer         ;reply payload is 00
    MOVLW   1                   ;reply payload is 1 byte
    MOVWF   ReplyLength         ;set the length
    BANKSEL PORTA               ;Bank 0
    BSF     PORTA,1             ;RA1 high = I2C bus in use
    CALL    MakeAddress         ;address shifted left, write bit 0
    CALL    I2CStart            ;START
    MOVF    AddressByte,W       ;load the address byte
    CALL    I2CSend             ;send it
    MOVLW   RxBuffer+1          ;the data bytes start after the address
    MOVWF   FSR                 ;point FSR at the first data byte
    DECF    PayloadLength,W     ;W = number of data bytes
    MOVWF   LoopCount           ;use it as the loop counter
WriteLoop:
    MOVF    INDF,W              ;load the next data byte
    CALL    I2CSend             ;send it
    INCF    FSR,F               ;move to the next byte
    DECFSZ  LoopCount,F         ;one fewer byte to go
    GOTO    WriteLoop           ;more bytes left
    CALL    I2CStop             ;STOP
    GOTO    FinishI2C           ;send the reply or the I2C error

DoRead:
    MOVF    PayloadLength,W     ;load the length
    XORLW   2                   ;read must have exactly 2 bytes (address, count)
    BTFSS   STATUS,2            ;skip if it does
    GOTO    BadLength           ;otherwise reject it
    MOVF    RxBuffer+1,W        ;load the count NN
    BTFSC   STATUS,2            ;is NN zero?
    GOTO    BadLength           ;zero-byte read is rejected
    SUBLW   23                  ;C = 1 if NN <= 23
    BTFSS   STATUS,0            ;skip if NN is 23 or less
    GOTO    BadLength           ;too many bytes
    CALL    CheckAddress        ;is the address 08-77?
    MOVF    RequestError,F      ;did the check fail?
    BTFSS   STATUS,2            ;skip if it passed
    GOTO    BridgeError         ;invalid address
    CLRF    ReplyBuffer         ;first reply byte is 00
    MOVF    RxBuffer+1,W        ;load NN
    MOVWF   LoopCount           ;use it as the loop counter
    ADDLW   1                   ;W = NN + 1
    MOVWF   ReplyLength         ;reply is 00 plus NN data bytes
    BANKSEL PORTA               ;Bank 0
    BSF     PORTA,1             ;RA1 high = I2C bus in use
    CALL    MakeAddress         ;address shifted left, write bit 0
    BSF     AddressByte,0       ;set the read bit
    CALL    I2CStart            ;START
    MOVF    AddressByte,W       ;load the address byte
    CALL    I2CSend             ;send it
    MOVLW   ReplyBuffer+1       ;data goes after the 00 byte
    MOVWF   FSR                 ;point FSR at it
ReadLoop:
    MOVF    LoopCount,W         ;load the bytes left
    XORLW   1                   ;is this the last byte?
    BTFSC   STATUS,2            ;yes?
    GOTO    ReadLast            ;go receive it with a NACK
    CALL    I2CReceiveAck       ;receive a byte, ACK it
    MOVWF   INDF                ;store it
    INCF    FSR,F               ;next slot
    DECF    LoopCount,F         ;one fewer byte to go
    GOTO    ReadLoop            ;keep reading
ReadLast:
    CALL    I2CReceiveNack      ;receive the last byte, NACK it
    MOVWF   INDF                ;store it
    CALL    I2CStop             ;STOP
    GOTO    FinishI2C           ;send the reply or the I2C error

CheckAddress:
    MOVF    RxBuffer,W          ;load the address
    SUBLW   0x07                ;C = 1 if address <= 0x07 (reserved)
    BTFSC   STATUS,0            ;skip if it is above 0x07
    GOTO    BadAddress          ;reserved address
    MOVF    RxBuffer,W          ;load the address
    SUBLW   0x77                ;C = 0 if address > 0x77 (reserved)
    BTFSS   STATUS,0            ;skip if it is 0x77 or less
    GOTO    BadAddress          ;reserved address
    RETURN                      ;address is fine
BadAddress:
    MOVLW   3                   ;bridge error 03
    MOVWF   RequestError        ;invalid 7-bit address
    RETURN                      ;done

MakeAddress:
    MOVF    RxBuffer,W          ;load the 7-bit address
    MOVWF   AddressByte         ;copy it
    BCF     STATUS,0            ;clear the carry so a 0 shifts in
    RLF     AddressByte,F       ;shift left, bit 0 = 0 (write)
    RETURN                      ;done

FinishI2C:
    BANKSEL PORTA               ;Bank 0
    BCF     PORTA,1             ;RA1 low = I2C bus finished
    MOVF    I2CError,F          ;did anything go wrong on the bus?
    BTFSC   STATUS,2            ;skip if there was an error
    GOTO    SendReply           ;no error - send the normal reply
    MOVF    I2CError,W          ;load the I2C error detail
    MOVWF   ErrorDetail         ;set the detail
    MOVLW   0x04                ;category 04 = I2C error
    MOVWF   ErrorCategory       ;set the category
    GOTO    SendError           ;send 24 45 02 04 SS

; ---------------- UART transmit ----------------
SendReply:
    MOVLW   0x24                ;start byte
    CALL    SendUartByte        ;send it
    MOVF    Command,W           ;the reply repeats the command
    CALL    SendUartByte        ;send it
    MOVF    ReplyLength,W       ;payload length
    CALL    SendUartByte        ;send it
    MOVLW   ReplyBuffer         ;reply payload starts here
    MOVWF   FSR                 ;point FSR at it
    MOVF    ReplyLength,W       ;load the payload length
    MOVWF   LoopCount           ;use it as the loop counter
ReplyLoop:
    MOVF    INDF,W              ;load the next payload byte
    CALL    SendUartByte        ;send it
    INCF    FSR,F               ;move to the next byte
    DECFSZ  LoopCount,F         ;one fewer byte to go
    GOTO    ReplyLoop           ;more bytes left
    RETURN                      ;done

SendError:
    MOVLW   0x24                ;start byte
    CALL    SendUartByte        ;send it
    MOVLW   0x45                ;error command
    CALL    SendUartByte        ;send it
    MOVLW   0x02                ;payload length is 2
    CALL    SendUartByte        ;send it
    MOVF    ErrorCategory,W     ;error category
    CALL    SendUartByte        ;send it
    MOVF    ErrorDetail,W       ;error detail
    CALL    SendUartByte        ;send it
    RETURN                      ;done

SendUartByte:                   ;W = byte to send
    BANKSEL PIR1                ;Bank 0
    BTFSS   PIR1,4              ;TXIF = 1 means the transmitter is ready
    GOTO    $-1                 ;not ready - keep waiting
    MOVWF   TXREG               ;sending starts when TXREG is written
    RETURN                      ;done

; ---------------- I2C building blocks ----------------
; Every routine does nothing if an I2C error has already happened.
I2CStart:
    MOVF    I2CError,F          ;any error so far?
    BTFSS   STATUS,2            ;skip if none
    RETURN                      ;an error already happened - do nothing
    BANKSEL PORTC               ;Bank 0
    BTFSS   PORTC,3             ;is SCL high?
    GOTO    SclHeldLow          ;no - something holds SCL low
    BTFSS   PORTC,4             ;is SDA high?
    GOTO    BusNotIdle          ;no - the bus is not idle
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,0           ;SEN = 1 sends a START
    CALL    WaitFlag            ;wait until it is finished
    RETURN                      ;done
SclHeldLow:
    MOVLW   4                   ;I2C error 04
    MOVWF   I2CError            ;SCL held LOW
    RETURN                      ;done
BusNotIdle:
    MOVLW   3                   ;I2C error 03
    MOVWF   I2CError            ;bus LOW / not idle
    RETURN                      ;done

I2CSend:                        ;W = byte to send
    MOVF    I2CError,F          ;any error so far? (W is not changed)
    BTFSS   STATUS,2            ;skip if none
    RETURN                      ;an error already happened - do nothing
    BANKSEL SSPBUF              ;Bank 0
    MOVWF   SSPBUF              ;sending starts when SSPBUF is written
    CALL    WaitFlag            ;wait until the byte and ACK slot are done
    BANKSEL SSPCON2             ;Bank 1
    BTFSS   SSPCON2,6           ;ACKSTAT = 0 means the slave ACKed
    RETURN                      ;it ACKed - nothing more to do
    MOVLW   1                   ;I2C error 01
    MOVWF   I2CError            ;address or data NACK
    RETURN                      ;done

I2CReceiveAck:                  ;returns the byte in W
    BANKSEL SSPCON2             ;Bank 1
    BCF     SSPCON2,5           ;ACKDT = 0 means we will send an ACK
    GOTO    I2CReceive          ;share the receive code below

I2CReceiveNack:                 ;returns the byte in W
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,5           ;ACKDT = 1 means we will send a NACK

I2CReceive:
    MOVF    I2CError,F          ;any error so far?
    BTFSS   STATUS,2            ;skip if none
    RETURN                      ;an error already happened - do nothing
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,3           ;RCEN = 1 starts receiving one byte
    CALL    WaitFlag            ;wait until the byte has arrived
    MOVF    I2CError,F          ;did the wait time out?
    BTFSS   STATUS,2            ;skip if it did not
    RETURN                      ;timed out - give up
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,4           ;ACKEN = 1 sends the ACK or NACK
    CALL    WaitFlag            ;wait until it has been sent
    BANKSEL SSPBUF              ;Bank 0
    MOVF    SSPBUF,W            ;W = the byte we received
    RETURN                      ;done

I2CStop:
    MOVF    I2CError,W          ;load the I2C error
    SUBLW   1                   ;C = 1 if the error is 0 or 1 (bus is still fine)
    BTFSS   STATUS,0            ;skip if a STOP is possible
    RETURN                      ;timeout or bus error - the bus was already reset
    BANKSEL SSPCON2             ;Bank 1
    BSF     SSPCON2,2           ;PEN = 1 sends a STOP
    CALL    WaitFlag            ;wait until it is finished
    RETURN                      ;done

WaitFlag:                       ;wait for SSPIF, give up after about 51 ms
    BANKSEL PIR1                ;Bank 0
    MOVLW   TimeoutStart        ;load the timeout count
    MOVWF   TimeoutHigh         ;set the high counter
    CLRF    TimeoutLow          ;low counter counts 256 times per pass
WaitLoop:
    BTFSC   PIR1,3              ;has the I2C hardware finished (SSPIF)?
    GOTO    FlagArrived         ;yes
    DECFSZ  TimeoutLow,F        ;count the low counter down
    GOTO    WaitLoop            ;keep waiting
    DECFSZ  TimeoutHigh,F       ;count the high counter down
    GOTO    WaitLoop            ;keep waiting
    MOVLW   2                   ;I2C error 02
    MOVWF   I2CError            ;timeout
    GOTO    BusReset            ;reset the MSSP (it returns to our caller)
FlagArrived:
    BCF     PIR1,3              ;clear SSPIF
    RETURN                      ;done

BusReset:
    BANKSEL SSPCON              ;Bank 0
    BCF     SSPCON,5            ;SSPEN = 0 turns the MSSP off and releases the lines
    BSF     SSPCON,5            ;SSPEN = 1 turns it back on
    BCF     PIR1,3              ;clear SSPIF
    BANKSEL SSPCON2             ;Bank 1
    CLRF    SSPCON2             ;cancel any pending START, STOP, receive or ACK
    MOVLW   0b10000000          ;SMP = 1 for 100 kHz
    MOVWF   SSPSTAT             ;write it to SSPSTAT again
    RETURN                      ;done

    END