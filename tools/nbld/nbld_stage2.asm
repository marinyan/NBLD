; NBLD v3 common stage-2 loader for the PC-8001 family.
;
; The tokenized N-BASIC first stage is identical for every title. It copies
; this routine to F800H, then starts it through a tiny F000H bootstrap. This
; routine decodes the Base64 NBLD package from REM lines into C800H, validates
; its self-description, expands every segment, restores the ordinary N80 ROM
; mapping, and jumps to the package entry address.

        ORG     0F800H

PORT_MEMORY_CONTROL EQU 31H
ROM_VISIBLE         EQU 00H
STAGING_ADDRESS     EQU 0C800H
PACKAGE_MAGIC       EQU STAGING_ADDRESS+0
PACKAGE_VERSION     EQU STAGING_ADDRESS+4
PACKAGE_HEADER_SIZE EQU STAGING_ADDRESS+5
PACKAGE_TOTAL_SIZE  EQU STAGING_ADDRESS+6
PACKAGE_ENTRY       EQU STAGING_ADDRESS+8
PACKAGE_SEGMENTS    EQU STAGING_ADDRESS+10
SEGMENT_LIST        EQU STAGING_ADDRESS+32
NBLD_VERSION        EQU 03H
NBLD_HEADER_SIZE    EQU 32
NBLD_CODEC_LZSS12   EQU 01H
LOADER_STACK_TOP    EQU 0FB00H

BASIC_RELOCATOR_START:
        DI
        LD      SP,LOADER_STACK_TOP

        ; N-BASIC program chains begin at 8001H on some ROMs and 8021H on
        ; others. Accept only a plausible line-20 record before scanning.
        LD      IX,08001H
        CALL    VALIDATE_BASIC_BASE
        JR      Z,DECODE_PAYLOAD_SETUP
        LD      IX,08021H
        CALL    VALIDATE_BASIC_BASE
        JP      NZ,LOADER_ERROR

DECODE_PAYLOAD_SETUP:
        LD      DE,STAGING_ADDRESS

DECODE_FIND_LINE:
        LD      L,(IX+0)
        LD      H,(IX+1)
        LD      A,H
        OR      L
        JP      Z,LOADER_ERROR
        PUSH    HL
        POP     IY
        LD      A,(IX+4)
        CP      08EH                 ; tokenized REM
        JP      NZ,DECODE_NEXT_LINE
        LD      A,(IX+5)
        CP      'E'                  ; final REM E marker
        JP      Z,DECODE_COMPLETE
        CP      'D'                  ; REM D<base64...>
        JP      NZ,DECODE_NEXT_LINE
        PUSH    IX
        POP     HL
        LD      A,L
        ADD     A,6
        LD      L,A
        JR      NC,DECODE_BASE64_GROUP
        INC     H

DECODE_BASE64_GROUP:
        LD      A,(HL)
        OR      A
        JP      Z,DECODE_NEXT_LINE
        CP      '='
        JP      Z,LOADER_ERROR
        INC     HL
        CALL    BASE64_VALUE
        LD      (BASE64_VALUE_0),A

        LD      A,(HL)
        OR      A
        JP      Z,LOADER_ERROR
        CP      '='
        JP      Z,LOADER_ERROR
        INC     HL
        CALL    BASE64_VALUE
        LD      (BASE64_VALUE_1),A

        LD      A,(HL)
        OR      A
        JP      Z,LOADER_ERROR
        LD      (BASE64_CHAR_2),A
        INC     HL
        CALL    BASE64_VALUE
        LD      (BASE64_VALUE_2),A

        LD      A,(HL)
        OR      A
        JP      Z,LOADER_ERROR
        LD      (BASE64_CHAR_3),A
        INC     HL
        CALL    BASE64_VALUE
        LD      (BASE64_VALUE_3),A

        PUSH    DE
        LD      A,(BASE64_VALUE_0)
        ADD     A,A
        ADD     A,A
        LD      D,A
        LD      A,(BASE64_VALUE_1)
        RRCA
        RRCA
        RRCA
        RRCA
        AND     03H
        OR      D
        POP     DE
        LD      (DE),A
        INC     DE

        LD      A,(BASE64_CHAR_2)
        CP      '='
        JP      Z,DECODE_PADDING_TWO
        PUSH    DE
        LD      A,(BASE64_VALUE_1)
        AND     0FH
        RLCA
        RLCA
        RLCA
        RLCA
        LD      D,A
        LD      A,(BASE64_VALUE_2)
        RRCA
        RRCA
        AND     0FH
        OR      D
        POP     DE
        LD      (DE),A
        INC     DE

        LD      A,(BASE64_CHAR_3)
        CP      '='
        JP      Z,DECODE_PADDING_ONE
        PUSH    DE
        LD      A,(BASE64_VALUE_2)
        AND     03H
        RRCA
        RRCA
        LD      D,A
        LD      A,(BASE64_VALUE_3)
        OR      D
        POP     DE
        LD      (DE),A
        INC     DE
        JP      DECODE_BASE64_GROUP

DECODE_PADDING_TWO:
        LD      A,(BASE64_CHAR_3)
        CP      '='
        JP      NZ,LOADER_ERROR
DECODE_PADDING_ONE:
        LD      A,(HL)
        OR      A
        JP      NZ,LOADER_ERROR
        JP      DECODE_NEXT_LINE

DECODE_NEXT_LINE:
        PUSH    IY
        POP     IX
        JP      DECODE_FIND_LINE

DECODE_COMPLETE:
        LD      (DECODE_END),DE

        ; Verify magic, version, fixed header size, and decoded package size.
        LD      HL,PACKAGE_MAGIC
        LD      DE,NBLD_MAGIC
        LD      B,4
NBLD_MAGIC_LOOP:
        LD      A,(DE)
        CP      (HL)
        JP      NZ,LOADER_ERROR
        INC     DE
        INC     HL
        DJNZ    NBLD_MAGIC_LOOP
        LD      A,(PACKAGE_VERSION)
        CP      NBLD_VERSION
        JP      NZ,LOADER_ERROR
        LD      A,(PACKAGE_HEADER_SIZE)
        CP      NBLD_HEADER_SIZE
        JP      NZ,LOADER_ERROR
        LD      HL,(PACKAGE_TOTAL_SIZE)
        LD      BC,STAGING_ADDRESS
        ADD     HL,BC
        LD      DE,(DECODE_END)
        OR      A
        SBC     HL,DE
        JP      NZ,LOADER_ERROR

        LD      A,(PACKAGE_SEGMENTS)
        OR      A
        JP      Z,LOADER_ERROR
        LD      (SEGMENTS_LEFT),A
        LD      HL,(PACKAGE_ENTRY)
        LD      (SAVED_ENTRY),HL
        LD      IX,SEGMENT_LIST

LOAD_NEXT_SEGMENT:
        LD      A,(IX+0)
        OUT     (PORT_MEMORY_CONTROL),A
        LD      A,(IX+1)
        CP      NBLD_CODEC_LZSS12
        JP      NZ,LOADER_ERROR

        LD      E,(IX+2)
        LD      D,(IX+3)
        PUSH    DE
        POP     IY
        LD      L,(IX+4)
        LD      H,(IX+5)
        LD      A,H
        OR      L
        JP      Z,LOADER_ERROR
        LD      (LZ_REMAINING),HL

        LD      C,(IX+6)
        LD      B,(IX+7)
        LD      A,B
        OR      C
        JP      Z,LOADER_ERROR
        PUSH    IX
        POP     HL
        LD      DE,8
        ADD     HL,DE
        ADD     HL,BC
        LD      (PACKED_END),HL
        LD      DE,8
        ADD     IX,DE

        CALL    UNPACK_LZSS_FORWARD
        PUSH    IX
        POP     HL
        LD      DE,(PACKED_END)
        OR      A
        SBC     HL,DE
        JP      NZ,LOADER_ERROR

        LD      A,(SEGMENTS_LEFT)
        DEC     A
        LD      (SEGMENTS_LEFT),A
        JP      NZ,LOAD_NEXT_SEGMENT

START_PAYLOAD:
        LD      A,ROM_VISIBLE
        OUT     (PORT_MEMORY_CONTROL),A
        LD      HL,(SAVED_ENTRY)
        JP      (HL)

VALIDATE_BASIC_BASE:
        LD      A,(IX+2)
        CP      20
        RET     NZ
        LD      A,(IX+3)
        OR      A
        RET

BASE64_VALUE:
        CP      '='
        JR      Z,BASE64_VALUE_ZERO
        CP      '+'
        JR      Z,BASE64_VALUE_PLUS
        CP      '/'
        JR      Z,BASE64_VALUE_SLASH
        CP      '0'
        JP      C,LOADER_ERROR
        CP      '9'+1
        JR      C,BASE64_VALUE_DIGIT
        CP      'A'
        JP      C,LOADER_ERROR
        CP      'Z'+1
        JR      C,BASE64_VALUE_UPPER
        CP      'a'
        JP      C,LOADER_ERROR
        CP      'z'+1
        JR      C,BASE64_VALUE_LOWER
        JP      LOADER_ERROR
BASE64_VALUE_UPPER:
        SUB     'A'
        RET
BASE64_VALUE_LOWER:
        SUB     'a'-26
        RET
BASE64_VALUE_DIGIT:
        SUB     '0'-52
        RET
BASE64_VALUE_PLUS:
        LD      A,62
        RET
BASE64_VALUE_SLASH:
        LD      A,63
        RET
BASE64_VALUE_ZERO:
        XOR     A
        RET

; Flags describe eight items, least-significant bit first. A set bit is one
; literal byte. A clear bit is a 12-bit backward distance plus a 3..18-byte
; match. The segment descriptor supplies the exact expanded and packed sizes.
UNPACK_LZSS_FORWARD:
UNPACK_LZSS_NEXT_FLAGS:
        LD      A,(IX+0)
        INC     IX
        LD      (LZ_FLAGS),A
        LD      A,8
        LD      (LZ_ITEMS_LEFT),A
UNPACK_LZSS_ITEM:
        LD      A,(LZ_FLAGS)
        RRCA
        LD      (LZ_FLAGS),A
        JR      NC,UNPACK_LZSS_MATCH
        LD      A,(IX+0)
        INC     IX
        LD      (IY+0),A
        INC     IY
        LD      HL,(LZ_REMAINING)
        DEC     HL
        LD      (LZ_REMAINING),HL
        LD      A,H
        OR      L
        RET     Z
        JR      UNPACK_LZSS_ITEM_DONE
UNPACK_LZSS_MATCH:
        LD      E,(IX+0)
        INC     IX
        LD      A,(IX+0)
        INC     IX
        LD      D,A
        AND     0FH
        ADD     A,3
        LD      (LZ_MATCH_LENGTH),A
        LD      A,D
        RRCA
        RRCA
        RRCA
        RRCA
        AND     0FH
        LD      D,A
        PUSH    IY
        POP     HL
        OR      A
        SBC     HL,DE
        EX      DE,HL
        LD      A,(LZ_MATCH_LENGTH)
        LD      B,A
UNPACK_LZSS_MATCH_LOOP:
        LD      A,(DE)
        LD      (IY+0),A
        INC     DE
        INC     IY
        DJNZ    UNPACK_LZSS_MATCH_LOOP
        LD      A,(LZ_MATCH_LENGTH)
        LD      E,A
        LD      D,0
        LD      HL,(LZ_REMAINING)
        OR      A
        SBC     HL,DE
        LD      (LZ_REMAINING),HL
        LD      A,H
        OR      L
        RET     Z
UNPACK_LZSS_ITEM_DONE:
        LD      A,(LZ_ITEMS_LEFT)
        DEC     A
        LD      (LZ_ITEMS_LEFT),A
        JP      NZ,UNPACK_LZSS_ITEM
        JP      UNPACK_LZSS_NEXT_FLAGS

NBLD_MAGIC:         DB "NBLD"
BASE64_VALUE_0:     DB 0
BASE64_VALUE_1:     DB 0
BASE64_VALUE_2:     DB 0
BASE64_VALUE_3:     DB 0
BASE64_CHAR_2:      DB 0
BASE64_CHAR_3:      DB 0
DECODE_END:         DW 0
SEGMENTS_LEFT:      DB 0
SAVED_ENTRY:        DW 0
PACKED_END:         DW 0
LZ_FLAGS:           DB 0
LZ_ITEMS_LEFT:      DB 0
LZ_MATCH_LENGTH:    DB 0
LZ_REMAINING:       DW 0

LOADER_ERROR:
        LD      A,ROM_VISIBLE
        OUT     (PORT_MEMORY_CONTROL),A
        LD      A,0E1H
        LD      (0C800H),A
LOADER_ERROR_HALT:
        HALT
        JR      LOADER_ERROR_HALT

BASIC_RELOCATOR_END:
        END     BASIC_RELOCATOR_START
