/*
 * main.s - Classic Space Invaders Video Game in Bare-Metal ARM Assembly
 * Architecture: ARMv6-M (Cortex-M0+) for Raspberry Pi Pico (RP2040)
 * Pure Assembly - 100% Bare-Metal (No SDK, No Arduino, No External Libraries)
 *
 * Direct Hardware Control:
 *   - OLED SH1106 128x64 via I2C0 (GP4=SDA, GP5=SCL)
 *   - KY-023 Joystick via ADC (GP26=VRX, GP27=VRY)
 *   - Button Z (SW) via SIO GPIO14 with pull-up (Fire Laser / Start / Restart)
 *   - Hardware Timer via RP2040 ALARM0 and NVIC IRQ 0 (60 FPS)
 *
 * Game State Machine:
 *   0: STATE_MENU     (Static Start Screen, waits for Button Z)
 *   1: STATE_PLAYING  (60 FPS Physics, Invader March, Collisions, HUD)
 *   2: STATE_GAMEOVER (Victory/Defeat Screen, Total Timer Halt, Reset on Button Z)
 */

    .syntax unified
    .cpu cortex-m0plus
    .thumb

    .global main

    /* External drivers */
    .extern system_init
    .extern video_init
    .extern oled_flush
    .extern fb_clear
    .extern fb_fill
    .extern fb_draw_pixel
    .extern fb_draw_rect_fill
    .extern fb_draw_rect
    .extern fb_draw_vline_dotted
    .extern fb_draw_char
    .extern fb_draw_string
    .extern fb_draw_number

    .extern inputs_init
    .extern read_button_z
    .extern read_adc_vrx
    .extern read_adc_vry

    .extern timer_init
    .extern timer_start
    .extern timer_stop
    .extern timer_wait_tick
    .extern tick_counter

/* Game States */
    .equ STATE_MENU,        0
    .equ STATE_PLAYING,     1
    .equ STATE_GAMEOVER,    2

/* Game Constants */
    .equ NUM_ALIENS,        12          /* 2 rows of 6 aliens */
    .equ ALIEN_W,           8
    .equ ALIEN_H,           6
    .equ ALIEN_X_SPACING,   16
    .equ ALIEN_Y_SPACING,   10
    .equ CANNON_W,          11
    .equ CANNON_H,          6
    .equ CANNON_Y,          54

/* ============================================================================
 * RAM Data for Space Invaders State Machine & Physics
 * ============================================================================ */
    .section .bss
    .align 2

game_state:
    .word 0                 /* 0 = Menu, 1 = Playing, 2 = Game Over */

score:
    .word 0
player_lives:
    .word 0
winner:
    .word 0                 /* 1 = Earth Saved (Win), 0 = Invaded (Loss) */

/* Player Cannon */
player_x:
    .word 0                 /* 4 to 113 */

/* Player Laser */
laser_active:
    .word 0                 /* 1 if firing, 0 if ready */
laser_x:
    .word 0
laser_y:
    .word 0

/* Alien Fleet */
fleet_x:
    .word 0                 /* Left edge of fleet */
fleet_y:
    .word 0                 /* Top edge of fleet */
fleet_dir:
    .word 0                 /* +1 (moving right) or -1 (moving left) */
fleet_tick:
    .word 0                 /* Movement cadence counter */
aliens_left:
    .word 0                 /* Count of living aliens (starts at 12) */

/* Alien array: 12 words (1 = alive, 0 = destroyed) */
alien_alive:
    .space 48               /* 12 * 4 bytes */

/* Enemy Bomb */
bomb_active:
    .word 0
bomb_x:
    .word 0
bomb_y:
    .word 0
bomb_cooldown:
    .word 0

/* ============================================================================
 * Text Strings (RODATA)
 * ============================================================================ */
    .section .rodata
    .align 2

str_title_space:    .asciz "SPACE INVADERS"
str_sub_arch:       .asciz "ARQUITECTURA II"
str_press_z:        .asciz "PULSE BOTON Z"
str_game_over:      .asciz "GAME OVER"
str_victory:        .asciz "TIERRA A SALVO!"
str_defeat:         .asciz "INVASION TOTAL!"
str_hud_score:      .asciz "PTS:"
str_hud_lives:      .asciz "VIDAS:"
str_final_score:    .asciz "PUNTOS:"
str_restart:        .asciz "PULSE Z REINICIAR"

/* 8x6 Alien Invader Sprite Bitmaps (6 bytes, each row is 8 bits wide) */
alien_sprite_row0:  .byte 0x42  /* .X....X. */
alien_sprite_row1:  .byte 0x24  /* ..X..X.. */
alien_sprite_row2:  .byte 0x7E  /* .XXXXXX. */
alien_sprite_row3:  .byte 0xDB  /* XX.XX.XX */
alien_sprite_row4:  .byte 0xFF  /* XXXXXXXX */
alien_sprite_row5:  .byte 0xA5  /* X.X..X.X */

/* ============================================================================
 * Main Entry Point
 * ============================================================================ */
    .section .text
    .align 2
    .thumb_func
main:
    push    {r4, lr}

    /* 1. Master System Hardware Initialization (XOSC, Clocks, Resets, LED) */
    bl      system_init

    /* 2. Initialize Peripherals */
    bl      inputs_init         /* Joystick (GP26/27 ADC) and Button Z (GP14) */
    bl      video_init          /* OLED SH1106 I2C0 & Framebuffer */
    bl      timer_init          /* 60 FPS Hardware Timer (NVIC IRQ 0) */

    /* 3. Initial State: Menu */
    ldr     r0, =game_state
    movs    r1, #STATE_MENU
    str     r1, [r0]

/* ============================================================================
 * Master Game Loop
 * ============================================================================ */
master_game_loop:
    ldr     r0, =game_state
    ldr     r0, [r0]

    cmp     r0, #STATE_MENU
    bne     not_menu
    b       run_state_menu
not_menu:
    cmp     r0, #STATE_PLAYING
    bne     not_playing
    b       run_state_playing
not_playing:
    cmp     r0, #STATE_GAMEOVER
    bne     master_game_loop
    b       run_state_gameover

/* ============================================================================
 * STATE 0: MENU PRINCIPAL
 * Static start screen with title, starts game when button Z is pressed
 * ============================================================================ */
run_state_menu:
    bl      fb_clear

    /* Outer decorative border */
    movs    r0, #2
    movs    r1, #2
    movs    r2, #124
    movs    r3, #60
    bl      fb_draw_rect

    /* Title "SPACE INVADERS" at (16, 12) */
    movs    r0, #16
    movs    r1, #12
    ldr     r2, =str_title_space
    bl      fb_draw_string

    /* Subtitle "ARQUITECTURA II" at (20, 26) */
    movs    r0, #20
    movs    r1, #26
    ldr     r2, =str_sub_arch
    bl      fb_draw_string

    /* Prompt "PULSE BOTON Z" at (26, 44) */
    movs    r0, #26
    movs    r1, #44
    ldr     r2, =str_press_z
    bl      fb_draw_string

    bl      oled_flush

menu_wait_button:
    bl      read_button_z
    cmp     r0, #1
    beq     menu_start_game

    /* Wait for 60 FPS hardware timer tick to save power */
    bl      timer_wait_tick

    /* Re-flush menu periodically (every 16 ticks ~ 250 ms)
     * Ensures display appears reliably on cold boot or wire reconnect */
    ldr     r0, =tick_counter
    ldr     r0, [r0]
    movs    r1, #15
    ands    r0, r1
    cmp     r0, #0
    bne     menu_wait_button

    bl      oled_flush
    b       menu_wait_button

menu_start_game:
    /* Debounce button: wait for release */
wait_release_menu:
    bl      read_button_z
    cmp     r0, #1
    bne     init_game_session
    bl      timer_wait_tick
    b       wait_release_menu

init_game_session:
    /* Reset Score and Lives */
    ldr     r0, =score
    movs    r1, #0
    str     r1, [r0]

    ldr     r0, =player_lives
    movs    r1, #3                      /* 3 Lives */
    str     r1, [r0]

    /* Initialize Player Cannon */
    ldr     r0, =player_x
    movs    r1, #58
    str     r1, [r0]

    /* Initialize Projectiles */
    ldr     r0, =laser_active
    movs    r1, #0
    str     r1, [r0]
    ldr     r0, =bomb_active
    str     r1, [r0]
    ldr     r0, =bomb_cooldown
    movs    r1, #60
    str     r1, [r0]

    /* Initialize Alien Fleet */
    ldr     r0, =fleet_x
    movs    r1, #10
    str     r1, [r0]

    ldr     r0, =fleet_y
    movs    r1, #12
    str     r1, [r0]

    ldr     r0, =fleet_dir
    movs    r1, #1                      /* Move right initially */
    str     r1, [r0]

    ldr     r0, =fleet_tick
    movs    r1, #0
    str     r1, [r0]

    ldr     r0, =aliens_left
    movs    r1, #NUM_ALIENS
    str     r1, [r0]

    /* Set all 12 aliens to alive */
    ldr     r0, =alien_alive
    movs    r1, #1
    movs    r2, #0
init_aliens_loop:
    cmp     r2, #NUM_ALIENS
    bge     aliens_init_done
    lsls    r3, r2, #2                  /* offset = index * 4 */
    str     r1, [r0, r3]
    adds    r2, r2, #1
    b       init_aliens_loop
aliens_init_done:

    /* Switch state to PLAYING */
    ldr     r0, =game_state
    movs    r1, #STATE_PLAYING
    str     r1, [r0]

    /* Start/Restart Hardware Timer */
    bl      timer_start

    b       master_game_loop

    .ltorg

/* ============================================================================
 * STATE 1: JUEGO EN CURSO (PLAYING)
 * 60 FPS Hardware Timer, Analog Control, Fleet March, Bombing, HUD
 * ============================================================================ */
run_state_playing:
    /* 1. Synchronize to 60 FPS hardware timer interrupt (No delay loops!) */
    bl      timer_wait_tick

    /* 2. Read Joystick and Update Player Cannon */
    bl      update_player_cannon

    /* 3. Update Player Laser */
    bl      update_player_laser

    /* 4. Update Alien Fleet March & Descend */
    bl      update_alien_fleet

    /* 5. Update Enemy Bombs */
    bl      update_enemy_bombs

    /* 6. Check Laser vs Alien Collisions */
    bl      check_laser_alien_collisions

    /* 7. Check Win / Loss Conditions */
    ldr     r0, =game_state
    ldr     r0, [r0]
    cmp     r0, #STATE_GAMEOVER
    beq     game_ended_jump

    /* 8. Render Scene to Framebuffer */
    bl      render_space_scene

    /* 9. Push Framebuffer to OLED Display */
    bl      oled_flush

game_ended_jump:
    b       master_game_loop

/* ----------------------------------------------------------------------------
 * update_player_cannon: Interprets ADC Joystick Variation for Fluid Movement
 * ---------------------------------------------------------------------------- */
    .thumb_func
update_player_cannon:
    push    {r4, r5, lr}

    /* Read VRX (GP26 / ADC0) */
    bl      read_adc_vrx
    mov     r4, r0              /* r4 = vrx (0..4095) */

    /* Read VRY (GP27 / ADC1) */
    bl      read_adc_vry
    mov     r5, r0              /* r5 = vry (0..4095) */

    /* Auto-detect joystick orientation: use axis with greater deflection */
    ldr     r2, =2048
    subs    r0, r4, r2
    bge     chk_dx_pos
    rsbs    r0, r0, #0
chk_dx_pos:
    mov     r3, r0              /* r3 = abs(vrx - 2048) */

    subs    r0, r5, r2
    bge     chk_dy_pos
    rsbs    r0, r0, #0
chk_dy_pos:                     /* r0 = abs(vry - 2048) */

    cmp     r0, r3
    ble     use_vrx_axis
    mov     r4, r5              /* use vry value if greater deflection */

use_vrx_axis:
    /* Map ADC (0..4095) to Cannon X: (val * 105) >> 12 + 4 -> range 4 to 109 */
    movs    r0, #105
    muls    r4, r0
    lsrs    r4, r4, #12
    adds    r4, r4, #4

    /* Clamp between 4 and 113 */
    cmp     r4, #4
    bge     px_min_ok
    movs    r4, #4
px_min_ok:
    cmp     r4, #113
    ble     px_max_ok
    movs    r4, #113
px_max_ok:

    ldr     r0, =player_x
    str     r4, [r0]

    /* Check Button Z (Fire Cannon Laser) */
    bl      read_button_z
    cmp     r0, #1
    bne     fire_done

    /* Button Z is pressed: fire laser if not currently active */
    ldr     r0, =laser_active
    ldr     r1, [r0]
    cmp     r1, #0
    bne     fire_done

    /* Fire new laser! */
    movs    r1, #1
    str     r1, [r0]

    ldr     r0, =laser_x
    adds    r2, r4, #5          /* Center of cannon */
    str     r2, [r0]

    ldr     r0, =laser_y
    movs    r2, #52             /* Just above cannon */
    str     r2, [r0]

fire_done:
    pop     {r4, r5, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * update_player_laser: Advances laser position upward
 * ---------------------------------------------------------------------------- */
    .thumb_func
update_player_laser:
    push    {r4, lr}

    ldr     r0, =laser_active
    ldr     r1, [r0]
    cmp     r1, #0
    beq     laser_update_done

    /* Advance laser upward by 3 pixels */
    ldr     r1, =laser_y
    ldr     r2, [r1]
    subs    r2, r2, #3
    str     r2, [r1]

    /* If reached top of screen (HUD border at Y=9), deactivate */
    cmp     r2, #10
    bgt     laser_update_done

    movs    r1, #0
    str     r1, [r0]            /* laser_active = 0 */

laser_update_done:
    pop     {r4, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * update_alien_fleet: Marches aliens horizontally and drops them down at edges
 * ---------------------------------------------------------------------------- */
    .thumb_func
update_alien_fleet:
    push    {r4, r5, r6, r7, lr}

    /* Cadence: move fleet every N frames (speed increases as aliens die) */
    ldr     r0, =aliens_left
    ldr     r1, [r0]

    /* Cadence threshold: 8 frames if > 6 aliens, 4 frames if <= 6 aliens */
    movs    r2, #8
    cmp     r1, #6
    bgt     cadence_set
    movs    r2, #4
cadence_set:

    ldr     r0, =fleet_tick
    ldr     r3, [r0]
    adds    r3, r3, #1
    str     r3, [r0]
    cmp     r3, r2
    blt     fleet_done

    /* Reset tick */
    movs    r3, #0
    str     r3, [r0]

    /* Calculate bounding box of living aliens */
    ldr     r4, =fleet_x
    ldr     r5, [r4]            /* r5 = current fleet_x */

    ldr     r6, =fleet_dir
    ldr     r7, [r6]            /* r7 = current fleet_dir (+1 or -1) */

    /* Move fleet horizontally */
    adds    r5, r5, r7
    adds    r5, r5, r7          /* Step by 2 pixels */
    str     r5, [r4]

    /* Find min and max X of all living aliens */
    ldr     r4, =alien_alive
    movs    r0, #127            /* min_x */
    movs    r1, #0              /* max_x */
    movs    r2, #0              /* index (0..11) */

bbox_loop:
    cmp     r2, #NUM_ALIENS
    bge     bbox_done

    lsls    r3, r2, #2
    ldr     r3, [r4, r3]
    cmp     r3, #0
    beq     bbox_next

    /* Compute alien X = fleet_x + (index % 6) * 16 */
    /* index % 6 */
    mov     r3, r2
div6_loop:
    cmp     r3, #6
    blt     div6_done
    subs    r3, r3, #6
    b       div6_loop
div6_done:
    lsls    r3, r3, #4          /* col * 16 */
    adds    r3, r5, r3          /* alien_x */

    /* Compare min */
    cmp     r3, r0
    bge     not_new_min
    mov     r0, r3
not_new_min:
    /* Compare max */
    adds    r3, r3, #ALIEN_W
    cmp     r3, r1
    ble     not_new_max
    mov     r1, r3
not_new_max:

bbox_next:
    adds    r2, r2, #1
    b       bbox_loop

bbox_done:
    /* Check edge collisions */
    /* Left edge (min_x <= 4) */
    cmp     r0, #4
    bgt     chk_right_edge

    /* Reached left wall: reverse to right and descend */
    movs    r7, #1
    str     r7, [r6]

    ldr     r0, =fleet_y
    ldr     r1, [r0]
    adds    r1, r1, #3          /* Descend 3 pixels */
    str     r1, [r0]
    b       chk_invasion

chk_right_edge:
    /* Right edge (max_x >= 124) */
    cmp     r1, #124
    blt     chk_invasion

    /* Reached right wall: reverse to left and descend */
    movs    r7, #0
    subs    r7, r7, #1          /* -1 */
    str     r7, [r6]

    ldr     r0, =fleet_y
    ldr     r1, [r0]
    adds    r1, r1, #3          /* Descend 3 pixels */
    str     r1, [r0]

chk_invasion:
    /* If aliens descended to player altitude (fleet_y >= 42), invasion succeeds! */
    ldr     r0, =fleet_y
    ldr     r0, [r0]
    cmp     r0, #42
    blt     fleet_done

    /* Player Defeat! */
    ldr     r0, =winner
    movs    r1, #0              /* 0 = Invaders won */
    str     r1, [r0]

    ldr     r0, =game_state
    movs    r1, #STATE_GAMEOVER
    str     r1, [r0]

    bl      timer_stop

fleet_done:
    pop     {r4, r5, r6, r7, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * update_enemy_bombs: Drops bombs from random living aliens towards player
 * ---------------------------------------------------------------------------- */
    .thumb_func
update_enemy_bombs:
    push    {r4, r5, r6, lr}

    ldr     r0, =bomb_active
    ldr     r1, [r0]
    cmp     r1, #0
    bne     move_active_bomb

    /* Bomb is not active: check cooldown */
    ldr     r2, =bomb_cooldown
    ldr     r3, [r2]
    subs    r3, r3, #1
    str     r3, [r2]
    cmp     r3, #0
    bgt     bombs_done

    /* Reset cooldown (approx 60 frames ~ 1 second) */
    movs    r3, #50
    str     r3, [r2]

    /* Find a living alien to drop bomb */
    ldr     r4, =alien_alive
    movs    r5, #0

find_bomber_loop:
    cmp     r5, #NUM_ALIENS
    bge     bombs_done

    /* Select pseudo-random index using tick_counter */
    ldr     r0, =tick_counter
    ldr     r0, [r0]
    adds    r0, r0, r5
    movs    r1, #11
    ands    r0, r1              /* 0..11 */

    lsls    r1, r0, #2
    ldr     r1, [r4, r1]
    cmp     r1, #1
    beq     spawn_bomb_at_alien

    adds    r5, r5, #1
    b       find_bomber_loop

spawn_bomb_at_alien:
    /* Compute alien position */
    /* col = r0 % 6, row = r0 / 6 */
    mov     r1, r0
    movs    r2, #0              /* row */
div6_b_loop:
    cmp     r1, #6
    blt     div6_b_done
    subs    r1, r1, #6
    adds    r2, r2, #1
    b       div6_b_loop
div6_b_done:                    /* r1 = col, r2 = row */

    ldr     r3, =fleet_x
    ldr     r3, [r3]
    lsls    r1, r1, #4          /* col * 16 */
    adds    r3, r3, r1
    adds    r3, r3, #4          /* Bomb X = center of alien */

    ldr     r4, =fleet_y
    ldr     r4, [r4]
    movs    r5, #10
    muls    r2, r5              /* row * 10 */
    adds    r4, r4, r2
    adds    r4, r4, #7          /* Bomb Y = bottom of alien */

    ldr     r0, =bomb_x
    str     r3, [r0]
    ldr     r0, =bomb_y
    str     r4, [r0]
    ldr     r0, =bomb_active
    movs    r1, #1
    str     r1, [r0]
    b       bombs_done

move_active_bomb:
    /* Move bomb down by 2 pixels */
    ldr     r2, =bomb_y
    ldr     r3, [r2]
    adds    r3, r3, #2
    str     r3, [r2]

    /* Check collision with player cannon (Y = 54..60) */
    cmp     r3, #54
    blt     chk_bomb_ground
    cmp     r3, #61
    bgt     chk_bomb_ground

    /* Check X overlap: bomb_x within player_x .. player_x + CANNON_W */
    ldr     r4, =bomb_x
    ldr     r4, [r4]            /* bomb_x */

    ldr     r5, =player_x
    ldr     r5, [r5]            /* player_x */

    cmp     r4, r5
    blt     chk_bomb_ground
    mov     r6, r5
    adds    r6, #CANNON_W
    cmp     r4, r6
    bgt     chk_bomb_ground

    /* HIT PLAYER CANNON! */
    movs    r1, #0
    str     r1, [r0]            /* bomb_active = 0 */

    ldr     r4, =player_lives
    ldr     r5, [r4]
    subs    r5, r5, #1
    str     r5, [r4]

    /* Check if lives depleted */
    cmp     r5, #0
    bgt     bombs_done

    /* Player Defeat! */
    ldr     r0, =winner
    movs    r1, #0              /* 0 = Loss */
    str     r1, [r0]

    ldr     r0, =game_state
    movs    r1, #STATE_GAMEOVER
    str     r1, [r0]

    bl      timer_stop
    b       bombs_done

chk_bomb_ground:
    /* Deactivate if reached bottom of screen */
    cmp     r3, #62
    blt     bombs_done
    movs    r1, #0
    str     r1, [r0]

bombs_done:
    pop     {r4, r5, r6, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * check_laser_alien_collisions: Detects player laser hitting alien invaders
 * ---------------------------------------------------------------------------- */
    .thumb_func
check_laser_alien_collisions:
    push    {r4, r5, r6, r7, lr}

    ldr     r0, =laser_active
    ldr     r1, [r0]
    cmp     r1, #0
    beq     coll_done

    ldr     r2, =laser_x
    ldr     r4, [r2]            /* r4 = laser_x */

    ldr     r3, =laser_y
    ldr     r5, [r3]            /* r5 = laser_y */

    /* Check against each alien */
    ldr     r6, =alien_alive
    movs    r7, #0              /* index = 0..11 */

alien_coll_loop:
    cmp     r7, #NUM_ALIENS
    bge     coll_done

    lsls    r0, r7, #2
    ldr     r0, [r6, r0]
    cmp     r0, #1
    bne     alien_coll_next

    /* Compute alien position: ax, ay */
    mov     r1, r7
    movs    r2, #0              /* row */
div6_c_loop:
    cmp     r1, #6
    blt     div6_c_done
    subs    r1, r1, #6
    adds    r2, r2, #1
    b       div6_c_loop
div6_c_done:                    /* r1 = col, r2 = row */

    ldr     r3, =fleet_x
    ldr     r3, [r3]
    lsls    r1, r1, #4          /* col * 16 */
    adds    r1, r3, r1          /* r1 = ax */

    ldr     r3, =fleet_y
    ldr     r3, [r3]
    movs    r0, #10
    muls    r2, r0              /* row * 10 */
    adds    r2, r3, r2          /* r2 = ay */

    /* Bounding box check:
     * laser_x >= ax AND laser_x <= ax + ALIEN_W
     * laser_y >= ay AND laser_y <= ay + ALIEN_H
     */
    cmp     r4, r1
    blt     alien_coll_next
    mov     r0, r1
    adds    r0, #ALIEN_W
    cmp     r4, r0
    bgt     alien_coll_next

    cmp     r5, r2
    blt     alien_coll_next
    adds    r0, r2, #ALIEN_H
    cmp     r5, r0
    bgt     alien_coll_next

    /* HIT ALIEN! */
    /* 1. Destroy Alien */
    lsls    r0, r7, #2
    movs    r1, #0
    str     r1, [r6, r0]

    /* 2. Deactivate Laser */
    ldr     r0, =laser_active
    str     r1, [r0]

    /* 3. Increase Score (+20 pts) */
    ldr     r0, =score
    ldr     r1, [r0]
    adds    r1, r1, #20
    str     r1, [r0]

    /* 4. Decrement remaining aliens */
    ldr     r0, =aliens_left
    ldr     r1, [r0]
    subs    r1, r1, #1
    str     r1, [r0]

    /* 5. Check Victory Condition: all 12 aliens destroyed! */
    cmp     r1, #0
    bgt     coll_done

    /* Player Victory! Earth is saved! */
    ldr     r0, =winner
    movs    r1, #1              /* 1 = Earth Saved */
    str     r1, [r0]

    ldr     r0, =game_state
    movs    r1, #STATE_GAMEOVER
    str     r1, [r0]

    bl      timer_stop
    b       coll_done

alien_coll_next:
    adds    r7, r7, #1
    b       alien_coll_loop

coll_done:
    pop     {r4, r5, r6, r7, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * render_space_scene: Draws playfield, HUD, aliens, cannon, lasers, and bombs
 * ---------------------------------------------------------------------------- */
    .thumb_func
render_space_scene:
    push    {r4, r5, r6, r7, lr}

    bl      fb_clear

    /* 1. HUD: "PTS: [score]   VIDAS: [lives]" at Y = 1 */
    movs    r0, #4
    movs    r1, #1
    ldr     r2, =str_hud_score
    bl      fb_draw_string

    movs    r0, #28
    movs    r1, #1
    ldr     r2, =score
    ldr     r2, [r2]
    bl      fb_draw_number

    movs    r0, #72
    movs    r1, #1
    ldr     r2, =str_hud_lives
    bl      fb_draw_string

    movs    r0, #112
    movs    r1, #1
    ldr     r2, =player_lives
    ldr     r2, [r2]
    bl      fb_draw_number

    /* Top HUD divider line */
    movs    r0, #0
    movs    r1, #9
    movs    r2, #128
    movs    r3, #1
    bl      fb_draw_rect_fill

    /* 2. Draw Living Alien Invaders */
    ldr     r4, =alien_alive
    movs    r5, #0              /* index = 0..11 */

render_aliens_loop:
    cmp     r5, #NUM_ALIENS
    bge     aliens_rendered

    lsls    r0, r5, #2
    ldr     r0, [r4, r0]
    cmp     r0, #1
    bne     next_render_alien

    /* Calculate alien position */
    mov     r1, r5
    movs    r2, #0              /* row */
div6_r_loop:
    cmp     r1, #6
    blt     div6_r_done
    subs    r1, r1, #6
    adds    r2, r2, #1
    b       div6_r_loop
div6_r_done:

    ldr     r3, =fleet_x
    ldr     r3, [r3]
    lsls    r1, r1, #4          /* col * 16 */
    adds    r6, r3, r1          /* r6 = ax */

    ldr     r3, =fleet_y
    ldr     r3, [r3]
    movs    r0, #10
    muls    r2, r0              /* row * 10 */
    adds    r7, r3, r2          /* r7 = ay */

    /* Draw 8x6 Invader Sprite at (r6, r7) */
    mov     r0, r6
    mov     r1, r7
    bl      draw_alien_sprite

next_render_alien:
    adds    r5, r5, #1
    b       render_aliens_loop

aliens_rendered:

    /* 3. Draw Player Cannon at player_x */
    ldr     r0, =player_x
    ldr     r4, [r0]            /* r4 = player_x */

    /* Cannon Base: (player_x, 57, 11, 4) */
    mov     r0, r4
    movs    r1, #57
    movs    r2, #11
    movs    r3, #4
    bl      fb_draw_rect_fill

    /* Cannon Turret: (player_x + 3, 55, 5, 2) */
    adds    r0, r4, #3
    movs    r1, #55
    movs    r2, #5
    movs    r3, #2
    bl      fb_draw_rect_fill

    /* Cannon Nozzle: (player_x + 5, 53, 1, 2) */
    adds    r0, r4, #5
    movs    r1, #53
    movs    r2, #1
    movs    r3, #2
    bl      fb_draw_rect_fill

    /* 4. Draw Player Laser (if active) */
    ldr     r0, =laser_active
    ldr     r0, [r0]
    cmp     r0, #0
    beq     chk_draw_bomb

    ldr     r0, =laser_x
    ldr     r0, [r0]
    ldr     r1, =laser_y
    ldr     r1, [r1]
    movs    r2, #1
    movs    r3, #4
    bl      fb_draw_rect_fill

chk_draw_bomb:
    /* 5. Draw Enemy Bomb (if active) */
    ldr     r0, =bomb_active
    ldr     r0, [r0]
    cmp     r0, #0
    beq     render_scene_done

    ldr     r0, =bomb_x
    ldr     r0, [r0]
    ldr     r1, =bomb_y
    ldr     r1, [r1]
    movs    r2, #2
    movs    r3, #3
    bl      fb_draw_rect_fill

render_scene_done:
    pop     {r4, r5, r6, r7, pc}

    .ltorg

/* ----------------------------------------------------------------------------
 * draw_alien_sprite: Draws an 8x6 pixel alien invader at (r0=X, r1=Y)
 * ---------------------------------------------------------------------------- */
    .thumb_func
draw_alien_sprite:
    push    {r4, r5, r6, r7, lr}
    mov     r4, r0              /* baseX */
    mov     r5, r1              /* baseY */

    ldr     r6, =alien_sprite_row0
    movs    r7, #0              /* row (0..5) */

alien_row_loop:
    cmp     r7, #6
    bge     alien_draw_done

    ldrb    r3, [r6, r7]        /* r3 = row byte */
    movs    r2, #0              /* col (0..7) */

alien_col_loop:
    cmp     r2, #8
    bge     alien_next_row

    /* Test bit (7 - col) of r3: (r3 >> (7 - col)) & 1 */
    movs    r0, #7
    subs    r0, r0, r2          /* shift */
    mov     r1, r3
    lsrs    r1, r0
    movs    r0, #1
    ands    r1, r0
    cmp     r1, #0
    beq     alien_skip_px

    /* Draw pixel at (baseX + col, baseY + row) */
    push    {r2, r3}
    adds    r0, r4, r2
    adds    r1, r5, r7
    bl      fb_draw_pixel
    pop     {r2, r3}

alien_skip_px:
    adds    r2, r2, #1
    b       alien_col_loop

alien_next_row:
    adds    r7, r7, #1
    b       alien_row_loop

alien_draw_done:
    pop     {r4, r5, r6, r7, pc}

    .ltorg

/* ============================================================================
 * STATE 2: GAME OVER
 * Screen showing match winner, physics halted, waiting for reset via Button Z
 * ============================================================================ */
run_state_gameover:
    bl      fb_clear

    /* Decorative border */
    movs    r0, #2
    movs    r1, #2
    movs    r2, #124
    movs    r3, #60
    bl      fb_draw_rect

    /* "GAME OVER" at (36, 8) */
    movs    r0, #36
    movs    r1, #8
    ldr     r2, =str_game_over
    bl      fb_draw_string

    /* Check who won: 1 = Player, 0 = Aliens */
    ldr     r0, =winner
    ldr     r0, [r0]
    cmp     r0, #1
    beq     show_player_victory

    /* Defeat: "INVASION TOTAL!" at (16, 22) */
    movs    r0, #16
    movs    r1, #22
    ldr     r2, =str_defeat
    bl      fb_draw_string
    b       show_gameover_score

show_player_victory:
    /* Victory: "TIERRA A SALVO!" at (16, 22) */
    movs    r0, #16
    movs    r1, #22
    ldr     r2, =str_victory
    bl      fb_draw_string

show_gameover_score:
    /* Final Score: "PUNTOS: [score]" at (36, 34) */
    movs    r0, #36
    movs    r1, #34
    ldr     r2, =str_final_score
    bl      fb_draw_string

    movs    r0, #80
    movs    r1, #34
    ldr     r2, =score
    ldr     r2, [r2]
    bl      fb_draw_number

    /* Prompt "PULSE Z REINICIAR" at (14, 48) */
    movs    r0, #14
    movs    r1, #48
    ldr     r2, =str_restart
    bl      fb_draw_string

    bl      oled_flush

gameover_wait_button:
    bl      read_button_z
    cmp     r0, #1
    beq     gameover_do_restart

    movs    r0, #100
delay_poll_go:
    subs    r0, r0, #1
    bne     delay_poll_go
    b       gameover_wait_button

gameover_do_restart:
    /* Wait for button release */
wait_release_restart:
    bl      read_button_z
    cmp     r0, #1
    beq     wait_release_restart

    /* Reinitialize state variables and return to Menu */
    ldr     r0, =score
    movs    r1, #0
    str     r1, [r0]

    ldr     r0, =winner
    str     r1, [r0]

    /* Restart hardware timer */
    bl      timer_start

    /* Transition back to Menu */
    ldr     r0, =game_state
    movs    r1, #STATE_MENU
    str     r1, [r0]

    b       master_game_loop

    .end
