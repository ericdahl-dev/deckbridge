// Generated from tools/lc6000-display-fw/vectors/messages.json by vectors/gen_protocol.py (#569). Don't edit.
#ifndef DFW_PROTOCOL_H
#define DFW_PROTOCOL_H

/// The host's header, then our command byte; the unit's replies start with the reply header.
#define DFW_HEADER { 0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10 }
#define DFW_REPLY_HEADER { 0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10 }
#define DFW_COMMAND 0x20
#define DFW_PROTOCOL_VERSION 1

/// Each op's number, and its one length counting the op (0: framed by len, as text is).
#define DFW_OP_CAPABILITY 0x00
#define DFW_OP_BEGIN 0x01
#define DFW_OP_END 0x02
#define DFW_OP_DECK 0x03
#define DFW_OP_TEXT 0x04
#define DFW_OP_TEMPO 0x05
#define DFW_OP_TIME 0x06
#define DFW_OP_STATE 0x07
#define DFW_OP_BEAT 0x08
#define DFW_OP_NEEDLE 0x09
#define DFW_OP_METER 0x0A
#define DFW_OP_PHASE 0x0B
#define DFW_OP_CAPABILITY_LENGTH 2
#define DFW_OP_BEGIN_LENGTH 2
#define DFW_OP_END_LENGTH 2
#define DFW_OP_DECK_LENGTH 9
#define DFW_OP_TEXT_LENGTH 0
#define DFW_OP_TEMPO_LENGTH 3
#define DFW_OP_TIME_LENGTH 5
#define DFW_OP_STATE_LENGTH 2
#define DFW_OP_BEAT_LENGTH 2
#define DFW_OP_NEEDLE_LENGTH 3
#define DFW_OP_METER_LENGTH 3
#define DFW_OP_PHASE_LENGTH 3

#define DFW_TEXT_MAX 96
#define DFW_TEXT_FIELDS 4
#define DFW_MESSAGE_MAX 112
#define DFW_DECK_MAX 4
#define DFW_PLAYER_MAX 5
#define DFW_BEAT_MAX 4

/// The state message's flag bits.
#define DFW_FLAG_LOADED 0x01
#define DFW_FLAG_PLAYING 0x02
#define DFW_FLAG_PLAY_PENDING 0x04
#define DFW_FLAG_CUE_HELD 0x08
#define DFW_FLAG_LOOP_ON 0x10
#define DFW_FLAG_STALE 0x20
#define DFW_FLAG_RESERVED 0x40

#define DFW_PHASE_UNKNOWN_VALUE (-8192)
#define DFW_SILENCE_MS 3000u
#define DFW_WARNING_SECONDS 60
#define DFW_BLINK_SECONDS 30
#define DFW_BLINK_HALF_MS 500u

#endif
