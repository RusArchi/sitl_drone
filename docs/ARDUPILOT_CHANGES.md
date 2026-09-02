# ArduPilot changes for `MOTOR_FAILURE_SET`

Every edit made to the ArduPilot tree for this project, with the line numbers they currently occupy.

`~/ardupilot` is a separate clone and is **not** part of this repository, so these changes live nowhere in git here except [`patches/ardupilot.patch`](patches/ardupilot.patch) and [`patches/mavlink.patch`](patches/mavlink.patch). Re-apply them after a fresh clone or a wiped submodule with `./scripts/apply_patches.sh`.

| | |
|---|---|
| ArduPilot base | `cbe0c39d5d` |
| `modules/mavlink` base | `13f2f735` |
| Line numbers valid as of | 2026-09-02 |

**Line numbers move.** They are correct against the bases above; after any rebase, regenerate this file rather than trusting it.

---

## `modules/mavlink/message_definitions/v1.0/ardupilotmega.xml`

The protocol change itself: a two-value enum at the end of the `<enums>` block, and the message at the end of `<messages>`. Everything else in this document is downstream of these 16 lines. Regenerating from this file produces msgid **11070**, a **4-byte** payload and **CRC-extra 97**.

**Lines 1351–1359**

```xml
1351 |     <enum name="MOTOR_FAILURE_TYPE">
1352 |       <description>Type of failure to inject on a motor output.</description>
1353 |       <entry name="MOTOR_FAILURE_TYPE_NONE" value="0">
1354 |         <description>Restore normal output.</description>
1355 |       </entry>
1356 |       <entry name="MOTOR_FAILURE_TYPE_STOPPED" value="1">
1357 |         <description>Force the output to zero.</description>
1358 |       </entry>
1359 |     </enum>
```

**Lines 2079–2085**

```xml
2079 |     <message id="11070" name="MOTOR_FAILURE_SET">
2080 |       <description>Fail and stop the chosen single motor (zero the speed command to ESC)</description>
2081 |       <field type="uint8_t" name="target_system">System ID.</field>
2082 |       <field type="uint8_t" name="target_component">Component ID.</field>
2083 |       <field type="uint8_t" name="motor">Motor to fail, 1 to 4, matching SERVO1 to SERVO4</field>
2084 |       <field type="uint8_t" name="failure_type" enum="MOTOR_FAILURE_TYPE">Motor stopped or restored</field>
2085 |     </message>
```

---

## `ArduCopter/GCS_MAVLink_Copter.h`

Declaration of the handler, in `protected:` beside the three existing `handle_message_*` helpers. No `override` — this replaces nothing in the base class.

**Lines 41–46**

```cpp
41 |     void handle_message_set_attitude_target(const mavlink_message_t &msg);
42 |     void handle_message_set_position_target_global_int(const mavlink_message_t &msg);
43 |     void handle_message_set_position_target_local_ned(const mavlink_message_t &msg);
44 |     // custom motor failure message injection
45 |     void handle_message_motor_failure_set(const mavlink_message_t &msg);
46 | 
```

---

## `ArduCopter/GCS_MAVLink_Copter.cpp`

The handler, and the `case` that reaches it. The handler validates the motor number before touching the library: the library's own guard returns silently, which is right for a library and useless to an operator. Without the check `motorfail 0` underflows to index 255 and `motorfail 7` sets a bit no frame reads — both look like success.

**Lines 1179–1199**

```cpp
1179 | // Custom message handle: Motor failure injection
1180 | void GCS_MAVLINK_Copter::handle_message_motor_failure_set(const mavlink_message_t &msg)
1181 | {
1182 |     // decode packet
1183 |     mavlink_motor_failure_set_t packet;
1184 |     mavlink_msg_motor_failure_set_decode(&msg, &packet);
1185 |     // apply
1186 |     if (packet.motor < 1 || packet.motor > AP_MOTORS_MAX_NUM_MOTORS ||
1187 |         !copter.motors->is_motor_enabled(packet.motor - 1)) {
1188 |         GCS_SEND_TEXT(MAV_SEVERITY_WARNING, "MOTOR_FAILURE_SET: bad motor %u",
1189 |                       (unsigned)packet.motor);
1190 |         return;
1191 |     }
1192 | 
1193 |     const bool failed = (packet.failure_type != MOTOR_FAILURE_TYPE_NONE);
1194 |     copter.motors->set_motor_failed(packet.motor-1, failed);
1195 | 
1196 |     GCS_SEND_TEXT(MAV_SEVERITY_INFO, "MOTOR_FAILURE_SET: motor %u type %u",
1197 |                   (unsigned)packet.motor, (unsigned)packet.failure_type);
1198 | }
1199 | 
```

**Lines 1219–1225**

```cpp
1219 |         break;
1220 | #endif
1221 |     case MAVLINK_MSG_ID_MOTOR_FAILURE_SET:
1222 |         handle_message_motor_failure_set(msg);
1223 |         break;
1224 |     default:
1225 |         GCS_MAVLINK::handle_message(msg);
```

---

## `libraries/AP_Motors/AP_MotorsMulticopter.h`

The setter is **public** because `Copter.h` declares `motors` as `AP_MotorsMulticopter *` — put it on `AP_MotorsMatrix` and the handler would need a cast. The mask is **protected** so `AP_MotorsMatrix` can read it directly, and carries an in-class `= 0`: an uninitialised mask would fail random motors at boot.

**Lines 72–82**

```cpp
72 |     // get minimum or maximum pwm value that can be output to motors
73 |     int16_t             get_pwm_output_min() const { return _pwm_min; }
74 |     int16_t             get_pwm_output_max() const { return _pwm_max; }
75 |     
76 |     //Custom addition:
77 |     //fail or restore a single motor output (0-based index)
78 |     //A failed motor is commanded to minimum PWM in output_to_motors(),
79 |     //downstream of the mixer, so the stability patch cannot undo it.
80 |     void set_motor_failed(uint8_t motor_index, bool failed);
81 |     uint32_t get_motor_fail_mask() const { return _motor_fail_mask; }
82 | 
```

**Lines 213–215**

```cpp
213 |     // motor output variables
214 |     bool                motor_enabled[AP_MOTORS_MAX_NUM_MOTORS];    // true if motor is enabled
215 |     uint32_t            _motor_fail_mask = 0; // By Ruslan. bit per motor index; 1 = commanded to stop
```

---

## `libraries/AP_Motors/AP_MotorsMulticopter.cpp`

The setter. The bounds check is not politeness — `1U << motor_index` past the type's width is undefined behaviour in C++, and on ARM the hardware shift uses the low 5 bits, so a shift by 32 silently becomes a shift by 0 and fails motor 1 instead.

**Lines 935–948**

```cpp
935 | // By Ruslan:
936 | // fail or restore a single motor output (0-based index)
937 | void AP_MotorsMulticopter::set_motor_failed(uint8_t motor_index, bool failed)
938 | {
939 |     if (motor_index >= AP_MOTORS_MAX_NUM_MOTORS){
940 |         //supplied index is bigger than the actual number of motors
941 |         return;
942 |     }
943 |     if (failed) {
944 |         _motor_fail_mask |= (1U << motor_index);
945 |     } else {
946 |         _motor_fail_mask &= ~(1U << motor_index);
947 |     }
948 | }
```

---

## `libraries/AP_Motors/AP_MotorsMatrix.cpp`

The kill. This is the last loop of `output_to_motors()`, downstream of the mixer, the stability patch, spool state, slew limiting and thrust linearisation — so nothing can rescale the zero away. `_actuator[i]` is deliberately left alone: the controller keeps computing a demand for the dead motor and never learns it is being ignored, which is what a dead ESC looks like from inside the flight code.

**Lines 177–187**

```cpp
177 |     // convert output to PWM and send to each motor
178 |     for (i = 0; i < AP_MOTORS_MAX_NUM_MOTORS; i++) {
179 |         if (motor_enabled[i]) {
180 |             if (_motor_fail_mask & (1U << i)) {
181 |                 // By Ruslan. Check the motor index against the motor fail mask.
182 |                 rc_write(i, get_pwm_output_min());
183 |             } else {
184 |                 rc_write(i, output_to_pwm(_actuator[i]));
185 |             }
186 |         }
187 |     }
```

---

## Rebuilding after a change here

```bash
# XML changed -> regenerate BOTH sides or the message is dropped silently
docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
  cd ~/ardupilot && ./waf copter'
docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
  MAVLINK_DIALECT=ardupilotmega pip install --force-reinstall \
    ~/ardupilot/modules/mavlink/pymavlink'

# C++ only -> just the build
docker exec sitl_drone bash -lc 'source ~/ardupilot/venv-ardupilot/bin/activate && \
  cd ~/ardupilot && ./waf copter'

# then always, so the diff is not lost with the tree
./scripts/make_patches.sh
```

See `PROJECT.md` §5 Technical ground truth for the full signal path and §7 Gotchas for the traps.
