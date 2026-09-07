#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_CONTROLLER_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_CONTROLLER_H

#include <stdint.h>

#define CHIAKI_CONTROLLER_TOUCHES_MAX 2

typedef struct ChiakiControllerTouch {
    uint16_t x;
    uint16_t y;
    int8_t id;
} ChiakiControllerTouch;

typedef struct ChiakiControllerState {
    uint32_t buttons;
    uint8_t l2_state;
    uint8_t r2_state;
    int16_t left_x;
    int16_t left_y;
    int16_t right_x;
    int16_t right_y;
    uint8_t touch_id_next;
    ChiakiControllerTouch touches[CHIAKI_CONTROLLER_TOUCHES_MAX];
    float gyro_x;
    float gyro_y;
    float gyro_z;
    float accel_x;
    float accel_y;
    float accel_z;
    float orient_x;
    float orient_y;
    float orient_z;
    float orient_w;
} ChiakiControllerState;

void chiaki_controller_state_set_idle(ChiakiControllerState *state);

#endif
