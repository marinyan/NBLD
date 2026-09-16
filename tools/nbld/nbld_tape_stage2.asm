; NBLD streaming tape transport v1. No whole-package RAM staging.
; The builder substitutes the baud selector; all game metadata arrives on tape.
        ORG 0F500H
        JP TAPE_START
TAPE_ERROR_CODE: DB 0
TAPE_STATE:      DB 0
STACK_TOP       EQU 0FB00H
LOADER_START    EQU 0F500H

TAPE_START:
        DI
        LD SP,STACK_TOP
        LD A,(0EA66H)
        AND 0C7H
        OR __NBLD_BAUD_BITS__
        LD (CONTROL30),A
        OUT (030H),A
        XOR A
        OUT (021H),A
        OUT (021H),A
        OUT (021H),A
        LD A,040H
        OUT (021H),A
        LD A,0CEH
        OUT (021H),A
        LD A,014H
        OUT (021H),A
        LD A,(CONTROL30)
        OR 8
        OUT (030H),A
        IN A,(020H)
        LD A,1
        LD (TAPE_STATE),A
        ; Bound the complete sync search, not just each UART byte.
        LD IX,4096
SYNC_RESTART:
        LD HL,TAPE_MAGIC
        LD B,8
SYNC_NEXT:
        PUSH BC
        PUSH IX
        POP BC
        LD A,B
        OR C
        POP BC
        JP Z,ERROR_FORMAT
        DEC IX
        CALL READ_RAW
        CP (HL)
        JR NZ,SYNC_RESTART
        INC HL
        DJNZ SYNC_NEXT
        LD HL,HEADER
        LD B,33
        CALL READ_BLOCK
        LD HL,HEADER
        LD DE,PACKAGE_MAGIC
        LD B,6
HEADER_MAGIC_LOOP:
        LD A,(DE)
        CP (HL)
        JP NZ,ERROR_FORMAT
        INC DE
        INC HL
        DJNZ HEADER_MAGIC_LOOP
        LD HL,(HEADER+6)
        LD DE,32
        OR A
        SBC HL,DE
        JP C,ERROR_FORMAT
        LD (TOTAL_LEFT),HL
        LD HL,(HEADER+8)
        LD (ENTRY_ADDRESS),HL
        LD A,(HEADER+10)
        OR A
        JP Z,ERROR_FORMAT
        LD (SEGMENTS_LEFT),A
        LD A,(HEADER+11)
        OR A
        JP NZ,ERROR_FORMAT
        LD HL,HEADER+28
        LD B,4
HEADER_RESERVED_LOOP:
        OR (HL)
        INC HL
        DJNZ HEADER_RESERVED_LOOP
        JP NZ,ERROR_FORMAT
        LD A,(HEADER+32)
        AND 0FDH
        JP NZ,ERROR_RANGE

NEXT_SEGMENT:
        LD HL,DESCRIPTOR
        LD B,8
        CALL READ_BLOCK
        ; Only ordinary upper RAM, optionally RAM under the BASIC ROM.
        LD A,(DESCRIPTOR)
        AND 0FDH
        JP NZ,ERROR_RANGE
        LD A,(DESCRIPTOR+1)
        CP 1
        JP NZ,ERROR_FORMAT
        LD DE,(DESCRIPTOR+2)
        BIT 7,D
        JR NZ,ROM_RANGE_OK
        LD A,(DESCRIPTOR)
        AND 2
        JP Z,ERROR_RANGE
ROM_RANGE_OK:
        LD HL,(DESCRIPTOR+4)
        LD A,H
        OR L
        JP Z,ERROR_RANGE
        LD (OUTPUT_LEFT),HL
        LD (OUTPUT_START),DE
        ADD HL,DE
        JR NC,END_NO_WRAP
        LD A,H
        OR L
        JP NZ,ERROR_RANGE
        ; A zero end with carry means exactly 10000H.
        LD HL,0FFFFH
        JR DEST_CHECK_PROTECTED
END_NO_WRAP:
        DEC HL
DEST_CHECK_PROTECTED:
        ; Last output address < F500H, or first >= FB00H.
        LD BC,LOADER_START
        OR A
        SBC HL,BC
        JR C,DESTINATION_OK
        EX DE,HL
        LD BC,STACK_TOP
        OR A
        SBC HL,BC
        JP C,ERROR_RANGE
DESTINATION_OK:
        LD HL,(DESCRIPTOR+6)
        LD A,H
        OR L
        JP Z,ERROR_FORMAT
        LD (PACKED_LEFT),HL
        LD DE,8
        ADD HL,DE
        JP C,ERROR_FORMAT
        EX DE,HL
        LD HL,(TOTAL_LEFT)
        OR A
        SBC HL,DE
        JP C,ERROR_FORMAT
        LD (TOTAL_LEFT),HL
        LD A,(DESCRIPTOR)
        OUT (031H),A
        LD IY,(DESCRIPTOR+2)
        CALL RESET_CRC
        LD A,2
        LD (TAPE_STATE),A
LZ_FLAGS_NEXT:
        CALL READ_PACKED
        LD (FLAGS),A
        LD A,8
        LD (ITEMS_LEFT),A
LZ_ITEM:
        LD A,(FLAGS)
        RRCA
        LD (FLAGS),A
        JR NC,LZ_MATCH
        CALL READ_PACKED
        LD (IY+0),A
        INC IY
        LD HL,(OUTPUT_LEFT)
        DEC HL
        LD (OUTPUT_LEFT),HL
        JR LZ_ITEM_DONE
LZ_MATCH:
        CALL READ_PACKED
        LD E,A
        CALL READ_PACKED
        LD D,A
        AND 15
        ADD A,3
        LD C,A
        LD B,0
        LD HL,(OUTPUT_LEFT)
        OR A
        SBC HL,BC
        JP C,ERROR_LZSS
        LD (OUTPUT_LEFT),HL
        LD A,D
        RRCA
        RRCA
        RRCA
        RRCA
        AND 15
        LD D,A
        OR E
        JP Z,ERROR_LZSS
        PUSH IY
        POP HL
        OR A
        SBC HL,DE
        JP C,ERROR_LZSS
        PUSH HL
        LD DE,(OUTPUT_START)
        OR A
        SBC HL,DE
        POP HL
        JP C,ERROR_LZSS
LZ_COPY:
        LD A,(HL)
        LD (IY+0),A
        INC HL
        INC IY
        DEC C
        JR NZ,LZ_COPY
LZ_ITEM_DONE:
        LD HL,(OUTPUT_LEFT)
        LD A,H
        OR L
        JR Z,SEGMENT_DONE
        LD A,(ITEMS_LEFT)
        DEC A
        LD (ITEMS_LEFT),A
        JP NZ,LZ_ITEM
        JP LZ_FLAGS_NEXT
SEGMENT_DONE:
        LD HL,(PACKED_LEFT)
        LD A,H
        OR L
        JP NZ,ERROR_LZSS
        CALL VERIFY_CRC
        LD A,(SEGMENTS_LEFT)
        DEC A
        LD (SEGMENTS_LEFT),A
        JP NZ,NEXT_SEGMENT
        LD HL,(TOTAL_LEFT)
        LD A,H
        OR L
        JP NZ,ERROR_FORMAT
        CALL STOP_TAPE
        LD A,(HEADER+32)
        OUT (031H),A
        LD A,3
        LD (TAPE_STATE),A
        LD HL,(ENTRY_ADDRESS)
        JP (HL)

READ_PACKED:
        PUSH HL
        LD HL,(PACKED_LEFT)
        LD A,H
        OR L
        JP Z,ERROR_LZSS
        DEC HL
        LD (PACKED_LEFT),HL
        POP HL
        JP READ_CRC

; Read metadata and verify its CRC BEFORE allowing writes to its destination.
READ_BLOCK:
        CALL RESET_CRC
READ_BLOCK_LOOP:
        CALL READ_CRC
        LD (HL),A
        INC HL
        DJNZ READ_BLOCK_LOOP
        JP VERIFY_CRC
RESET_CRC:
        PUSH HL
        LD HL,0FFFFH
        LD (CRC),HL
        POP HL
        RET
VERIFY_CRC:
        LD DE,(CRC)
        CALL READ_RAW
        CP E
        JP NZ,ERROR_CRC
        CALL READ_RAW
        CP D
        JP NZ,ERROR_CRC
        RET

; CRC-16/CCITT-FALSE; A and BC/DE/HL/IX/IY are preserved.
READ_CRC:
        CALL READ_RAW
        PUSH AF
        PUSH BC
        PUSH DE
        LD DE,(CRC)
        XOR D
        LD D,A
        LD B,8
TAPE_CRC_BIT:
        SLA E
        RL D
        JR NC,TAPE_CRC_NEXT
        LD A,D
        XOR 010H
        LD D,A
        LD A,E
        XOR 021H
        LD E,A
TAPE_CRC_NEXT:
        DJNZ TAPE_CRC_BIT
        LD (CRC),DE
        POP DE
        POP BC
        POP AF
        RET

; Preserves all registers except AF. Timeout also bounds truncated tapes.
READ_RAW:
        PUSH BC
        PUSH DE
        LD BC,0
        LD D,48
UART_POLL:
        IN A,(021H)
        AND 038H
        JP NZ,ERROR_UART
        IN A,(021H)
        AND 2
        JR NZ,UART_READY
        DEC BC
        LD A,B
        OR C
        JR NZ,UART_POLL
        DEC D
        JR NZ,UART_POLL
        LD A,1
        JP TAPE_ERROR
UART_READY:
        IN A,(020H)
        POP DE
        POP BC
        RET
STOP_TAPE:
        LD A,(CONTROL30)
        OUT (030H),A
        XOR A
        OUT (021H),A
        RET
ERROR_UART:
        LD A,2
        JR TAPE_ERROR
ERROR_CRC:
        LD A,3
        JR TAPE_ERROR
ERROR_FORMAT:
        LD A,4
        JR TAPE_ERROR
ERROR_RANGE:
        LD A,5
        JR TAPE_ERROR
ERROR_LZSS:
        LD A,6
TAPE_ERROR:
        LD (TAPE_ERROR_CODE),A
        LD SP,STACK_TOP
        CALL STOP_TAPE
        XOR A
        OUT (031H),A
        LD A,0FFH
        LD (TAPE_STATE),A
        LD HL,ERROR_TEXT
        LD DE,0F300H
        LD BC,ERROR_TEXT_END-ERROR_TEXT
        LDIR
ERROR_HALT:
        HALT
        JR ERROR_HALT

TAPE_MAGIC:     DB "NBLDT",1,0A5H,05AH
PACKAGE_MAGIC:  DB "NBLD",3,32
ERROR_TEXT:     DB "NBLD TAPE ERROR - RESET / RETRY"
ERROR_TEXT_END:
CONTROL30:      DB 0
SEGMENTS_LEFT:  DB 0
FLAGS:         DB 0
ITEMS_LEFT:    DB 0
CRC:           DW 0
ENTRY_ADDRESS: DW 0
TOTAL_LEFT:    DW 0
PACKED_LEFT:   DW 0
OUTPUT_LEFT:   DW 0
OUTPUT_START:  DW 0
HEADER:        DS 33
DESCRIPTOR:    DS 8
TAPE_LOADER_END:
        END TAPE_START
