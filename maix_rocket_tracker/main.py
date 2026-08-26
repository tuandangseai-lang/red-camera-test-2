"""SE selectable tracker for MaixCAM Lite.

MaixCAM is the only vision authority.  The iPhone selects one mode, MaixCAM
runs only that detector/class group, preserves one identity through ByteTrack,
and sends a filtered target to the ESP32 through the Type-C UART adapter.  The
ESP32 owns all servo timing and safety limits.
"""

from maix import app, camera, display, err, image, nn, pinmap, time, tracker, uart
import math
import os
import gc
import json


APP_VERSION = "1.22.0"
MOUNT_PROFILE = "MAIX_TILT_TOP"
MODEL_PATH = "/maixapp/apps/se_rocket_tracker/models/se_water_rocket_yolo11n.mud"
FALLBACK_MODEL_PATH = "/root/models/yolo11n.mud"
NANOTRACK_MODEL_PATH = "/root/models/nanotrack.mud"

# The four-pin Type-C adapter exposes MaixCAM UART0, not UART1.
# Adapter TX/RX are the SoC A16/A17 signals. ESP32 receives on GPIO21 and
# transmits on GPIO17; the UART wires must therefore be crossed.
UART_DEVICE = "/dev/ttyS0"
UART_BAUD = 115200
UART_TX_PIN = "A16"
UART_RX_PIN = "A17"
UART_TX_FUNCTION = "UART0_TX"
UART_RX_FUNCTION = "UART0_RX"

DETECT_CONFIDENCE = 0.16
DETECT_IOU = 0.42
ACQUIRE_SCORE_MIN = 0.29
REACQUIRE_SCORE_MIN = 0.20
ASSOCIATE_SCORE_MIN = 0.27
FAST_REACQUIRE_SCORE = 0.56
LOCK_CONFIRM_FRAMES = 2
LOST_AFTER_FRAMES = 4
REACQUIRE_MEMORY_MS = 3400
MAX_PREDICT_SECONDS = 0.50
# Rendering the small MaixCAM display less often leaves more NPU/CPU time for
# NanoTrack and UART. Target packets remain at the MG996R's real 50 Hz limit.
PREVIEW_INTERVAL_MS = 66
TARGET_REPORT_INTERVAL_MS = 20
IDLE_FRAME_INTERVAL_MS = 120
ENROLL_DURATION_MS = 3000
ENROLL_REPORT_INTERVAL_MS = 80
ENROLL_MIN_VISIBLE_RATIO = 0.02
MAX_SELECTION_CANDIDATES = 12
# The complete frozen candidate snapshot is sent once at the end of the scan.
# Repeating D/CHOOSE packets kept the CV loop busy enough to starve UART RX on
# this MaixCAM firmware, so reliability is handled by ESP32 command retries.
CANDIDATE_REPORT_INTERVAL_MS = 650
CHOOSE_REPORT_INTERVAL_MS = 650
REFINE_DURATION_MS = 3000
REFINE_MIN_VISIBLE_RATIO = 0.0
MULTIVIEW_DURATION_MS = 3000
MULTIVIEW_REPORT_INTERVAL_MS = 80
MULTIVIEW_DIVERSITY_MIN = 0.030
NANO_MIN_SCORE = 0.46
NANO_STRONG_SCORE = 0.68
NANO_REINIT_FRAMES = 24
YOLO_ROCKET_INTERVAL = 6
YOLO_GENERAL_INTERVAL = 8
NANO_MAX_CENTRE_JUMP_RATIO = 0.34
NANO_MIN_BOX_SIDE = 4
APPEARANCE_TEMPLATE_LIMIT = 8
APPEARANCE_DIVERSITY_MIN = 0.055
CUSTOM_ROCKET_CLASS_ID = 1000
PROFILE_LIMIT = 2
PROFILE_PATH = "/maixapp/apps/se_rocket_tracker/profiles.json"

STATE_IDLE = 0
STATE_ACQUIRE = 1
STATE_LOCKED = 2
STATE_WEAK = 3
STATE_LOST = 4

SUPPORTED_MODES = ("ROCKET", "PERSON", "ANIMAL", "OBJECT")
ANIMAL_CLASS_IDS = list(range(14, 24))
OBJECT_CLASS_IDS = list(range(1, 14)) + list(range(24, 80))
COCO_LABELS = (
    "PERSON", "BICYCLE", "CAR", "MOTORCYCLE", "AIRPLANE", "BUS",
    "TRAIN", "TRUCK", "BOAT", "TRAFFIC_LIGHT", "FIRE_HYDRANT",
    "STOP_SIGN", "PARKING_METER", "BENCH", "BIRD", "CAT", "DOG",
    "HORSE", "SHEEP", "COW", "ELEPHANT", "BEAR", "ZEBRA", "GIRAFFE",
    "BACKPACK", "UMBRELLA", "HANDBAG", "TIE", "SUITCASE", "FRISBEE",
    "SKIS", "SNOWBOARD", "SPORTS_BALL", "KITE", "BASEBALL_BAT",
    "BASEBALL_GLOVE", "SKATEBOARD", "SURFBOARD", "TENNIS_RACKET",
    "BOTTLE", "WINE_GLASS", "CUP", "FORK", "KNIFE", "SPOON", "BOWL",
    "BANANA", "APPLE", "SANDWICH", "ORANGE", "BROCCOLI", "CARROT",
    "HOT_DOG", "PIZZA", "DONUT", "CAKE", "CHAIR", "COUCH",
    "POTTED_PLANT", "BED", "DINING_TABLE", "TOILET", "TV", "LAPTOP",
    "MOUSE", "REMOTE", "KEYBOARD", "CELL_PHONE", "MICROWAVE", "OVEN",
    "TOASTER", "SINK", "REFRIGERATOR", "BOOK", "CLOCK", "VASE",
    "SCISSORS", "TEDDY_BEAR", "HAIR_DRIER", "TOOTHBRUSH",
)


def clamp(value, low, high):
    return low if value < low else high if value > high else value


def ticks_delta(now, before):
    value = now - before
    return value if value >= 0 else 1


def target_label(mode, class_id):
    if mode == "ROCKET":
        return "WATER_ROCKET"
    if 0 <= class_id < len(COCO_LABELS):
        return COCO_LABELS[class_id]
    return mode


def candidate_label(class_id):
    """Label one frozen proposal without forcing every box into the active tab."""
    if class_id == CUSTOM_ROCKET_CLASS_ID:
        return "WATER_ROCKET"
    if 0 <= class_id < len(COCO_LABELS):
        return COCO_LABELS[class_id]
    return "VUNG_TU_CHON"


class DetectionRecord:
    """Small detector-neutral record used by the universal 3-second scan."""
    def __init__(self, detected, class_id=None):
        self.x = detected.x
        self.y = detected.y
        self.w = detected.w
        self.h = detected.h
        self.class_id = detected.class_id if class_id is None else class_id
        self.score = detected.score


def crc8_xor(text):
    value = 0
    for byte in text.encode("ascii"):
        value ^= byte
    return value


def make_packet(payload):
    return "${0}*{1:02X}\n".format(payload, crc8_xor(payload))


def parse_packet(line):
    if not line or not line.startswith("$") or "*" not in line:
        return None
    body, crc_text = line[1:].rsplit("*", 1)
    try:
        if int(crc_text[:2], 16) != crc8_xor(body):
            return None
    except Exception:
        return None
    return body.split(",")


def iou(a, b):
    ax1, ay1, aw, ah = a
    bx1, by1, bw, bh = b
    ax2, ay2 = ax1 + aw, ay1 + ah
    bx2, by2 = bx1 + bw, by1 + bh
    xx1, yy1 = max(ax1, bx1), max(ay1, by1)
    xx2, yy2 = min(ax2, bx2), min(ay2, by2)
    inter = max(0, xx2 - xx1) * max(0, yy2 - yy1)
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


class AlphaBetaBox:
    """Small constant-velocity filter that does not allocate per frame."""

    def __init__(self):
        self.valid = False
        self.cx = self.cy = self.w = self.h = 0.0
        self.vx = self.vy = 0.0
        self.ax = self.ay = 0.0
        self.last_ms = 0

    def reset(self):
        self.valid = False
        self.vx = self.vy = 0.0
        self.ax = self.ay = 0.0
        self.last_ms = 0

    def predict(self, now_ms):
        if not self.valid:
            return None
        dt = clamp(ticks_delta(now_ms, self.last_ms) / 1000.0, 0.0, MAX_PREDICT_SECONDS)
        return (self.cx + self.vx * dt + 0.5 * self.ax * dt * dt,
                self.cy + self.vy * dt + 0.5 * self.ay * dt * dt,
                self.w, self.h)

    def update(self, box, now_ms, confidence):
        x, y, w, h = box
        measured_x = x + w * 0.5
        measured_y = y + h * 0.5
        if not self.valid:
            self.valid = True
            self.cx, self.cy = measured_x, measured_y
            self.w, self.h = float(w), float(h)
            self.vx = self.vy = 0.0
            self.ax = self.ay = 0.0
            self.last_ms = now_ms
            return

        dt = clamp(ticks_delta(now_ms, self.last_ms) / 1000.0, 0.01, 0.20)
        predicted_x = self.cx + self.vx * dt + 0.5 * self.ax * dt * dt
        predicted_y = self.cy + self.vy * dt + 0.5 * self.ay * dt * dt
        residual_x = measured_x - predicted_x
        residual_y = measured_y - predicted_y
        residual_distance = math.sqrt(residual_x * residual_x +
                                      residual_y * residual_y)
        current_speed = math.sqrt(self.vx * self.vx + self.vy * self.vy)
        # Detector boxes breathe by a few pixels even while the object is
        # motionless. Treat that as measurement noise; a genuine launch makes
        # a much larger residual and immediately selects the faster response.
        quiet_radius = max(2.4, min(w, h) * 0.045)
        quiet = residual_distance <= quiet_radius and current_speed < 38.0
        if quiet:
            alpha = clamp(0.22 + confidence * 0.20, 0.24, 0.42)
            beta = clamp(0.032 + confidence * 0.042, 0.032, 0.074)
            gamma = clamp(0.004 + confidence * 0.008, 0.004, 0.012)
            velocity_memory = 0.68
            acceleration_memory = 0.55
        else:
            alpha = clamp(0.50 + confidence * 0.36, 0.54, 0.86)
            beta = clamp(0.09 + confidence * 0.12, 0.10, 0.22)
            gamma = clamp(0.016 + confidence * 0.026, 0.018, 0.044)
            velocity_memory = 0.86
            acceleration_memory = 0.74
        self.cx = predicted_x + alpha * residual_x
        self.cy = predicted_y + alpha * residual_y
        # Damp residual velocity before adding the new measurement.  Without
        # this, one noisy box can leave a non-zero feed-forward command for
        # several frames and make an MG995 twitch around a stationary target.
        self.vx = clamp(self.vx * velocity_memory + self.ax * dt +
                        beta * residual_x / dt,
                        -1500.0, 1500.0)
        self.vy = clamp(self.vy * velocity_memory + self.ay * dt +
                        beta * residual_y / dt,
                        -1500.0, 1500.0)
        # A conservative acceleration term anticipates the first high-speed
        # launch frames.  Strong damping prevents a single bad box from making
        # the gimbal run away after the subject stops.
        dt2 = max(0.0004, dt * dt)
        self.ax = clamp(self.ax * acceleration_memory + gamma * residual_x / dt2,
                        -4200.0, 4200.0)
        self.ay = clamp(self.ay * acceleration_memory + gamma * residual_y / dt2,
                        -4200.0, 4200.0)
        size_alpha = 0.24 + confidence * 0.14
        self.w += size_alpha * (w - self.w)
        self.h += size_alpha * (h - self.h)
        self.last_ms = now_ms

    def coast(self, now_ms):
        predicted = self.predict(now_ms)
        if predicted is None:
            return
        self.cx, self.cy, self.w, self.h = predicted
        # Keep the last flight vector alive for ESP32's two-second predictive
        # search. The previous 0.90/frame decay erased the direction in only a
        # few hundred milliseconds and made the gimbal stop too early.
        self.vx *= 0.975
        self.vy *= 0.975
        self.ax *= 0.72
        self.ay *= 0.72
        self.last_ms = now_ms


class RocketTracker:
    def __init__(self):
        self.custom_model = os.path.exists(MODEL_PATH)
        self.active_mode = "ROCKET"
        selected_model, self.valid_class_ids = self._mode_configuration(self.active_mode)
        self.detector_path = selected_model
        self.detector = nn.YOLO11(model=selected_model, dual_buff=True)
        self.bottle_detector = None
        self.nano_tracker = (nn.NanoTrack(NANOTRACK_MODEL_PATH)
                             if os.path.exists(NANOTRACK_MODEL_PATH) else None)
        self.camera = camera.Camera(
            self.detector.input_width(),
            self.detector.input_height(),
            self.detector.input_format(),
        )
        self._ensure_bottle_detector()
        self.display = display.Display()
        self.byte_tracker = self._new_byte_tracker()
        self.serial = self._open_uart()
        self.filter = AlphaBetaBox()
        self.enabled = False
        self.state = STATE_IDLE
        self.sequence = 0
        self.frame_index = 0
        self.target_id = -1
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = False
        self.confirm_count = 0
        self.missing_frames = 0
        self.lost_started_ms = 0
        self.last_box = None
        self.last_confidence = 0.0
        self.rx_buffer = ""
        self.rx_chunks = []
        # MaixPy invokes this callback on its UART worker thread. Polling UART0
        # from the neural-inference loop intermittently stopped receiving after
        # the scan produced several outbound packets on this firmware.
        self.serial.set_received_callback(self._on_uart_received)
        self.last_status_ms = 0
        self.last_target_report_ms = 0
        self.last_preview_ms = 0
        self.last_fps_ms = time.ticks_ms()
        self.fps_frames = 0
        self.fps = 0.0
        self.enrolling = False
        self.enroll_started_ms = 0
        self.enroll_last_report_ms = 0
        self.enroll_total_frames = 0
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self.enroll_next_proposal_id = -1
        self.enrollment_class_id = -1
        self.appearance_template = None
        self.appearance_templates = []
        self.saved_profiles = self._load_saved_profiles()
        self.active_profile_slot = 0
        self.awaiting_selection = False
        self.selection_candidates = {}
        self.selection_order = []
        self.candidate_last_report_ms = 0
        self.choose_last_report_ms = 0
        self.candidate_report_index = 0
        self.refining = False
        self.refine_started_ms = 0
        self.refine_last_report_ms = 0
        self.refine_total_frames = 0
        self.refine_visible_frames = 0
        self.refine_signature_sum = None
        self.refine_signature_count = 0
        self.refine_signatures = []
        self.refine_manual = False
        self.multiview_active = False
        self.multiview_started_ms = 0
        self.multiview_last_report_ms = 0
        self.multiview_signatures = []
        self.selected_candidate_slot = -1
        self.selected_waiting_center = False
        self.identity_is_manual = False
        self.nano_active = False
        self.nano_last_score = 0.0
        self.nano_last_init_frame = -1000
        self.last_yolo_frame = -1000
        self.last_yolo_lock_frame = -1000
        self.tracking_source = "YOLO"
        self.locked_label = "WATER_ROCKET"

    def _load_saved_profiles(self):
        try:
            with open(PROFILE_PATH, "r") as profile_file:
                payload = json.load(profile_file)
            profiles = payload if isinstance(payload, dict) else {}
            clean = {}
            for slot in range(1, PROFILE_LIMIT + 1):
                profile = profiles.get(str(slot))
                if not isinstance(profile, dict):
                    continue
                mode = str(profile.get("mode", "OBJECT")).upper()
                templates = profile.get("templates", [])
                if mode not in SUPPORTED_MODES or not isinstance(templates, list):
                    continue
                valid_templates = []
                for signature in templates[:APPEARANCE_TEMPLATE_LIMIT]:
                    if isinstance(signature, list) and len(signature) >= 91:
                        valid_templates.append([float(value) for value in signature])
                if not valid_templates:
                    continue
                clean[str(slot)] = {
                    "mode": mode,
                    "label": str(profile.get("label", target_label(mode, -1))),
                    "class_id": int(profile.get("class_id", -1)),
                    "templates": valid_templates,
                }
            print("Loaded {0} saved identity profiles".format(len(clean)), flush=True)
            return clean
        except Exception:
            return {}

    def _persist_saved_profiles(self):
        temporary_path = PROFILE_PATH + ".tmp"
        try:
            serializable = {}
            for key, profile in self.saved_profiles.items():
                serializable[key] = {
                    "mode": profile["mode"],
                    "label": profile["label"],
                    "class_id": profile["class_id"],
                    # Five decimals are ample for the colour/edge descriptor
                    # and keep both profiles small enough for flash storage.
                    "templates": [
                        [round(float(value), 5) for value in signature]
                        for signature in profile["templates"]
                    ],
                }
            with open(temporary_path, "w") as profile_file:
                json.dump(serializable, profile_file)
            os.rename(temporary_path, PROFILE_PATH)
            return True
        except Exception as exception:
            print("Profile write failed: {0}".format(exception), flush=True)
            try:
                if os.path.exists(temporary_path):
                    os.remove(temporary_path)
            except Exception:
                pass
            return False

    def _save_profile(self, slot):
        if (slot < 1 or slot > PROFILE_LIMIT or
                not self.appearance_templates):
            return False
        self.saved_profiles[str(slot)] = {
            "mode": self.active_mode,
            "label": self.locked_label,
            "class_id": self.enrollment_class_id,
            "templates": [list(signature)
                          for signature in self.appearance_templates[:APPEARANCE_TEMPLATE_LIMIT]],
        }
        if not self._persist_saved_profiles():
            return False
        self.active_profile_slot = slot
        self._write("P,{0},SAVED,{1},{2}".format(
            slot, self.active_mode, self.locked_label
        ))
        print("Identity profile {0} saved ({1})".format(slot, self.active_mode),
              flush=True)
        return True

    def _delete_profile(self, slot):
        self.saved_profiles.pop(str(slot), None)
        if self.active_profile_slot == slot:
            self.active_profile_slot = 0
        if not self._persist_saved_profiles():
            return False
        self._write("P,{0},DELETED".format(slot))
        return True

    def _load_profile(self, slot, center_x, center_y, now_ms):
        profile = self.saved_profiles.get(str(slot))
        if profile is None:
            return False
        # Change model while disabled so _set_mode cannot start the ordinary
        # 3-second candidate scan. A reused identity goes straight to the
        # user's centre/refine step.
        self.enabled = False
        if not self._set_mode(profile["mode"]):
            return False
        self.enabled = True
        self._clear_target()
        self.enrolling = False
        self.awaiting_selection = False
        self.refining = False
        self.multiview_active = False
        self.active_profile_slot = slot
        self.enrollment_class_id = int(profile.get("class_id", -1))
        self.locked_label = str(profile.get("label", target_label(self.active_mode, -1)))
        self.appearance_templates = [list(signature)
                                     for signature in profile["templates"]]
        self.appearance_template = list(self.appearance_templates[0])
        width = float(max(1, self.camera.width()))
        height = float(max(1, self.camera.height()))
        center_x = clamp(center_x, 0.12, 0.88) * width
        center_y = clamp(center_y, 0.12, 0.88) * height
        if self.active_mode == "PERSON":
            box_w, box_h = width * 0.20, height * 0.34
        elif self.active_mode == "ROCKET":
            box_w, box_h = width * 0.17, height * 0.30
        else:
            box_w, box_h = width * 0.22, height * 0.22
        self.last_box = (
            clamp(center_x - box_w * 0.5, 0, width - box_w),
            clamp(center_y - box_h * 0.5, 0, height - box_h),
            box_w, box_h,
        )
        self.last_confidence = 0.62
        self.selected_candidate_slot = slot
        self.selected_waiting_center = True
        self.refine_manual = True
        self.identity_is_manual = True
        self.target_id = -1000 - slot
        self.state = STATE_ACQUIRE
        self._write("P,{0},LOADED,{1},{2}".format(
            slot, self.active_mode, self.locked_label
        ))
        print("Identity profile {0} loaded; waiting at saved optical centre".format(slot),
              flush=True)
        return True

    def _mode_configuration(self, mode):
        if mode == "ROCKET":
            # Class 0 is the custom water-rocket model; class 39 is COCO's
            # bottle class used to offer an empty PET bottle during selection.
            return (MODEL_PATH, [0, 39]) if self.custom_model else (FALLBACK_MODEL_PATH, [39])
        if mode == "PERSON":
            return FALLBACK_MODEL_PATH, [0]
        if mode == "ANIMAL":
            return FALLBACK_MODEL_PATH, ANIMAL_CLASS_IDS
        return FALLBACK_MODEL_PATH, OBJECT_CLASS_IDS

    def _set_mode(self, mode):
        mode = mode.upper()
        if mode not in SUPPORTED_MODES:
            return False
        model_path, class_ids = self._mode_configuration(mode)
        if mode != "ROCKET":
            self._release_bottle_detector()
        if model_path != self.detector_path:
            next_detector = nn.YOLO11(model=model_path, dual_buff=True)
            if (next_detector.input_width() != self.camera.width() or
                    next_detector.input_height() != self.camera.height()):
                raise RuntimeError("Tracking models must share one input size")
            previous_detector = self.detector
            self.detector = next_detector
            self.detector_path = model_path
            del previous_detector
            gc.collect()
        self.active_mode = mode
        self.valid_class_ids = class_ids
        if mode == "ROCKET":
            self._ensure_bottle_detector()
        self.state = STATE_ACQUIRE if self.enabled else STATE_IDLE
        self._clear_target()
        if self.enabled:
            self._begin_enrollment()
        print("Tracking mode: {0}".format(mode), flush=True)
        return True

    def _ensure_bottle_detector(self):
        if (not self.custom_model or self.active_mode != "ROCKET" or
                self.detector_path == FALLBACK_MODEL_PATH or
                self.bottle_detector is not None):
            return
        try:
            detector = nn.YOLO11(model=FALLBACK_MODEL_PATH, dual_buff=False)
            if (detector.input_width() != self.camera.width() or
                    detector.input_height() != self.camera.height()):
                del detector
                gc.collect()
                print("PET proposal model has incompatible input size", flush=True)
                return
            self.bottle_detector = detector
            print("PET proposal detector ready", flush=True)
        except Exception as exception:
            self.bottle_detector = None
            print("PET proposal detector unavailable: {0}".format(exception), flush=True)

    def _release_bottle_detector(self):
        if self.bottle_detector is None:
            return
        detector = self.bottle_detector
        self.bottle_detector = None
        del detector
        gc.collect()

    def _detect_objects(self, frame, include_bottle=False, bottle_only=False):
        objects = []
        if not bottle_only:
            objects = list(self.detector.detect(
                frame,
                conf_th=DETECT_CONFIDENCE,
                iou_th=DETECT_IOU,
            ))
        if include_bottle and self.bottle_detector is not None:
            bottle_objects = self.bottle_detector.detect(
                frame,
                conf_th=0.12,
                iou_th=DETECT_IOU,
            )
            for detected in bottle_objects:
                if detected.class_id == 39:
                    objects.append(detected)
        return objects

    def _detect_enrollment_objects(self, frame):
        """Return every visible proposal during the 3-second selection scan.

        The selected tab controls the tracker *after* the user taps a box.  It
        must not hide other visible objects while the user is still choosing.
        A custom rocket result receives a private class id so it cannot collide
        with COCO class 0 (PERSON) in the shared ByteTracker.
        """
        objects = []
        if self.detector_path == FALLBACK_MODEL_PATH:
            detected = self.detector.detect(
                frame, conf_th=0.12, iou_th=DETECT_IOU
            )
            objects.extend(DetectionRecord(item) for item in detected)
        else:
            # Rocket mode owns two neural nets. Running both sequentially on
            # every image halves the useful frame rate, so alternate them and
            # retain their proposals in the three-second spatial accumulator.
            run_general = (self.bottle_detector is not None and
                           self.frame_index % 2 == 1)
            if run_general:
                general = self.bottle_detector.detect(
                    frame, conf_th=0.10, iou_th=DETECT_IOU
                )
                objects.extend(DetectionRecord(item) for item in general)
            else:
                detected = self.detector.detect(
                    frame, conf_th=0.12, iou_th=DETECT_IOU
                )
                objects.extend(
                    DetectionRecord(item, CUSTOM_ROCKET_CLASS_ID)
                    for item in detected
                )
        return objects

    def _new_byte_tracker(self):
        return tracker.ByteTracker(
            35,   # retain identity briefly when detections disappear
            0.18,
            0.28,
            0.76,
            12,
        )

    def _open_uart(self):
        err.check_raise(pinmap.set_pin_function(UART_TX_PIN, UART_TX_FUNCTION), "UART TX mapping failed")
        err.check_raise(pinmap.set_pin_function(UART_RX_PIN, UART_RX_FUNCTION), "UART RX mapping failed")
        return uart.UART(UART_DEVICE, UART_BAUD)

    def _write(self, payload):
        self.serial.write_str(make_packet(payload))

    def _on_uart_received(self, _serial, data):
        try:
            chunk = bytes(data).decode("ascii", errors="ignore")
        except Exception:
            return
        if chunk:
            # list.append is atomic under MaixPy's Python runtime. Parsing and
            # all state changes remain on the CV thread in _read_commands().
            self.rx_chunks.append(chunk)

    def _read_commands(self):
        if not self.rx_chunks:
            return
        chunks = self.rx_chunks
        self.rx_chunks = []
        self.rx_buffer += "".join(chunks)
        if len(self.rx_buffer) > 512:
            self.rx_buffer = self.rx_buffer[-256:]
        while "\n" in self.rx_buffer:
            line, self.rx_buffer = self.rx_buffer.split("\n", 1)
            parts = parse_packet(line.strip())
            if not parts or parts[0] != "C" or len(parts) < 3:
                continue
            command = parts[2].upper()
            if command == "ARM":
                print("UART command: ARM", flush=True)
                self.enabled = True
                self.state = STATE_ACQUIRE
                self._clear_target()
                self._begin_enrollment()
                self._write("A,{0},ARMED".format(parts[1]))
            elif command in ("STOP", "DISARM"):
                print("UART command: {0}".format(command), flush=True)
                self.enabled = False
                self.state = STATE_IDLE
                self._clear_target()
                self._cancel_enrollment()
                self._write("A,{0},IDLE".format(parts[1]))
            elif command == "HOME":
                print("UART command: HOME", flush=True)
                self.enabled = False
                self.state = STATE_IDLE
                self._clear_target()
                self._cancel_enrollment()
                self._write("A,{0},HOME".format(parts[1]))
            elif command == "MODE" and len(parts) >= 4:
                if self._set_mode(parts[3]):
                    self._write("A,{0},MODE,{1}".format(parts[1], self.active_mode))
                else:
                    self._write("A,{0},MODE_ERROR".format(parts[1]))
            elif command == "SELECT" and len(parts) >= 4:
                try:
                    slot = int(parts[3])
                except Exception:
                    slot = -1
                if self._select_candidate(slot, time.ticks_ms()):
                    self._write("A,{0},SELECTED,{1}".format(parts[1], slot))
                else:
                    self._write("A,{0},SELECT_ERROR,{1}".format(parts[1], slot))
            elif command == "SELECT_POINT" and len(parts) >= 5:
                try:
                    point_x = int(parts[3])
                    point_y = int(parts[4])
                except Exception:
                    point_x, point_y = -1, -1
                if self._select_manual_point(point_x, point_y, time.ticks_ms()):
                    self._write("A,{0},SELECTED,0".format(parts[1]))
                else:
                    self._write("A,{0},SELECT_ERROR,0".format(parts[1]))
            elif command == "REFINE":
                if self._begin_refinement(self.selected_candidate_slot,
                                          time.ticks_ms()):
                    self._write("A,{0},REFINING,{1}".format(
                        parts[1], self.selected_candidate_slot
                    ))
                else:
                    self._write("A,{0},REFINE_ERROR".format(parts[1]))
            elif command == "MULTIVIEW":
                if self._begin_multiview(time.ticks_ms()):
                    self._write("A,{0},MULTIVIEW".format(parts[1]))
                else:
                    self._write("A,{0},MULTIVIEW_ERROR".format(parts[1]))
            elif command == "PROFILE_SAVE" and len(parts) >= 4:
                try:
                    slot = int(parts[3])
                except Exception:
                    slot = 0
                if not self._save_profile(slot):
                    self._write("P,{0},ERROR,SAVE".format(slot))
            elif command == "PROFILE_DELETE" and len(parts) >= 4:
                try:
                    slot = int(parts[3])
                except Exception:
                    slot = 0
                if not self._delete_profile(slot):
                    self._write("P,{0},ERROR,DELETE".format(slot))
            elif command == "PROFILE_LOAD" and len(parts) >= 6:
                try:
                    slot = int(parts[3])
                    center_x = int(parts[4]) / 1000.0
                    center_y = int(parts[5]) / 1000.0
                except Exception:
                    slot, center_x, center_y = 0, 0.5, 0.5
                if not self._load_profile(slot, center_x, center_y,
                                          time.ticks_ms()):
                    self._write("P,{0},ERROR,LOAD".format(slot))
            elif command == "PING":
                print("UART command: PING", flush=True)
                self._write("A,{0},PONG,{1},{2},{3}".format(
                    parts[1], APP_VERSION, self.active_mode, MOUNT_PROFILE
                ))

    def _clear_target(self):
        # ByteTrack keeps identities internally. Recreate it at each ARM/STOP/
        # HOME boundary so a previous session can never pull the gimbal toward
        # a stale position on the first frame of a new recording.
        self.byte_tracker = self._new_byte_tracker()
        self.target_id = -1
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = False
        self.confirm_count = 0
        self.missing_frames = 0
        self.lost_started_ms = 0
        self.last_box = None
        self.last_confidence = 0.0
        self.filter.reset()
        self.nano_active = False
        self.nano_last_score = 0.0
        self.nano_last_init_frame = -1000
        self.last_yolo_frame = -1000
        self.last_yolo_lock_frame = -1000
        self.tracking_source = "YOLO"
        self.locked_label = target_label(self.active_mode, -1)
        self.awaiting_selection = False
        self.selection_candidates = {}
        self.selection_order = []
        self.candidate_last_report_ms = 0
        self.choose_last_report_ms = 0
        self.candidate_report_index = 0
        self.refining = False
        self.refine_started_ms = 0
        self.refine_last_report_ms = 0
        self.refine_total_frames = 0
        self.refine_visible_frames = 0
        self.refine_signature_sum = None
        self.refine_signature_count = 0
        self.refine_signatures = []
        self.refine_manual = False
        self.multiview_active = False
        self.multiview_started_ms = 0
        self.multiview_last_report_ms = 0
        self.multiview_signatures = []
        self.selected_candidate_slot = -1
        self.selected_waiting_center = False
        self.identity_is_manual = False
        self.active_profile_slot = 0

    def _begin_enrollment(self):
        self.enrolling = True
        self.enroll_started_ms = time.ticks_ms()
        self.enroll_last_report_ms = 0
        self.enroll_total_frames = 0
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self.enroll_next_proposal_id = -1
        self.enrollment_class_id = -1
        self.appearance_template = None
        self.appearance_templates = []
        self.awaiting_selection = False
        self.selection_candidates = {}
        self.selection_order = []
        self.candidate_last_report_ms = 0
        self.choose_last_report_ms = 0
        self.candidate_report_index = 0
        self.refining = False
        self.refine_manual = False
        self.multiview_active = False
        self.multiview_started_ms = 0
        self.multiview_last_report_ms = 0
        self.multiview_signatures = []
        self.selected_candidate_slot = -1
        self.selected_waiting_center = False
        self.identity_is_manual = False
        self.state = STATE_ACQUIRE
        self._write("E,0,{0},START".format(self.active_mode))

    def _cancel_enrollment(self):
        self.enrolling = False
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self.enroll_next_proposal_id = -1
        self.awaiting_selection = False
        self.selection_candidates = {}
        self.selection_order = []
        self.candidate_report_index = 0
        self.choose_last_report_ms = 0
        self.refining = False
        self.refine_manual = False
        self.multiview_active = False
        self.multiview_started_ms = 0
        self.multiview_last_report_ms = 0
        self.multiview_signatures = []
        self.selected_candidate_slot = -1
        self.selected_waiting_center = False
        self.identity_is_manual = False

    def _appearance_signature(self, frame, box):
        """Spatial colour/edge descriptor for re-identifying one selected subject.

        YOLO supplies the semantic class and ByteTrack supplies motion identity.
        This descriptor is deliberately small so MaixCAM can compare a specific
        bottle/person/animal without a second neural network or extra heat.
        """
        x, y, w, h = box
        if w < 10 or h < 10:
            return None
        width = max(1, frame.width())
        height = max(1, frame.height())
        samples = []
        # Stay inside the subject.  For people, bias the samples toward the
        # torso/clothes so a yellow-shirt subject cannot be replaced by a
        # nearby person merely because both detections share the PERSON class.
        y_fractions = ((0.18, 0.34, 0.50, 0.68)
                       if self.active_mode == "PERSON"
                       else (0.22, 0.40, 0.58, 0.76))
        x_fractions = ((0.30, 0.42, 0.58, 0.70)
                       if self.active_mode == "PERSON"
                       else (0.22, 0.40, 0.58, 0.76))
        for fy in y_fractions:
            py = int(clamp(y + h * fy, 0, height - 1))
            for fx in x_fractions:
                px = int(clamp(x + w * fx, 0, width - 1))
                try:
                    pixel = frame.get_pixel(px, py, True)
                except Exception:
                    return None
                if not isinstance(pixel, (tuple, list)) or len(pixel) < 3:
                    return None
                red = float(pixel[0])
                green = float(pixel[1])
                blue = float(pixel[2])
                total = max(18.0, red + green + blue)
                # Chromaticity survives exposure changes better than raw RGB;
                # luminance and the later gradients retain markings/edges.
                samples.append((red / total, green / total,
                                (red * 0.299 + green * 0.587 +
                                 blue * 0.114) / 255.0))
        if not samples:
            return None
        spatial = []
        for sample in samples:
            spatial.extend(sample)
        gradients = []
        for row in range(4):
            for column in range(3):
                gradients.append(samples[row * 4 + column + 1][2] -
                                 samples[row * 4 + column][2])
        for row in range(3):
            for column in range(4):
                gradients.append(samples[(row + 1) * 4 + column][2] -
                                 samples[row * 4 + column][2])
        aspect = clamp(math.log(max(0.12, w / float(max(1, h)))) / 2.5,
                       -1.0, 1.0)
        # A global chromaticity histogram is much more discriminative than a
        # class label alone and remains stable when exposure changes.  It is
        # intentionally tiny (16 bins) so it adds almost no MaixCAM heat.
        colour_histogram = [0.0] * 16
        saturation_sum = 0.0
        luminance_sum = 0.0
        for red_chroma, green_chroma, luminance in samples:
            red_bin = int(clamp(red_chroma * 4.0, 0, 3))
            green_bin = int(clamp(green_chroma * 4.0, 0, 3))
            colour_histogram[red_bin * 4 + green_bin] += 1.0
            blue_chroma = max(0.0, 1.0 - red_chroma - green_chroma)
            saturation_sum += max(red_chroma, green_chroma, blue_chroma) - min(
                red_chroma, green_chroma, blue_chroma
            )
            luminance_sum += luminance
        inv_count = 1.0 / len(samples)
        colour_histogram = [value * inv_count for value in colour_histogram]
        return (spatial + gradients + [aspect] + colour_histogram +
                [saturation_sum * inv_count, luminance_sum * inv_count])

    def _appearance_similarity(self, signature):
        if signature is None:
            return None
        templates = self.appearance_templates
        if not templates and self.appearance_template is not None:
            templates = [self.appearance_template]
        if not templates:
            return None
        similarities = []
        for template in templates:
            if len(signature) != len(template) or len(signature) < 91:
                continue
            # 16 cells x (R chroma, G chroma, luminance), 24 gradients,
            # aspect, 16-bin colour histogram, saturation and luminance.
            spatial_error = sum(abs(signature[i] - template[i])
                                for i in range(48)) / 48.0
            gradient_error = sum(abs(signature[i] - template[i])
                                 for i in range(48, 72)) / 24.0
            shape_error = abs(signature[72] - template[72])
            colour_error = sum(abs(signature[i] - template[i])
                               for i in range(73, 89)) / 2.0
            saturation_error = abs(signature[89] - template[89])
            luminance_error = abs(signature[90] - template[90])
            similarities.append(clamp(
                1.0 - spatial_error * 0.80 - gradient_error * 0.45 -
                shape_error * 0.12 - colour_error * 0.95 -
                saturation_error * 0.30 - luminance_error * 0.10,
                0.0, 1.0
            ))
        if not similarities:
            return None
        # Keep several selected-subject views instead of averaging every view
        # into one blurry identity. The runner-up adds consensus and prevents a
        # single accidental hand/reflection template from winning by itself.
        similarities.sort(reverse=True)
        if len(similarities) == 1:
            return similarities[0]
        return similarities[0] * 0.76 + similarities[1] * 0.24

    def _signature_distance(self, first, second):
        if first is None or second is None or len(first) != len(second):
            return 1.0
        return sum(abs(first[index] - second[index])
                   for index in range(len(first))) / max(1.0, len(first))

    def _aim_point(self, box):
        """Return the control point, independent of the detector box size.

        Person mode aims near the eyes/head, animal mode near the head/upper
        body, while rockets and generic objects use the centre of their learned
        shape.  The detector still keeps the full box for identity and scale.
        """
        x, y, w, h = box
        vertical = 0.5
        if self.active_mode == "PERSON":
            vertical = 0.20
        elif self.active_mode == "ANIMAL":
            vertical = 0.31
        return x + w * 0.5, y + h * vertical

    def _update_motion_filter(self, box, now_ms, confidence):
        aim_x, aim_y = self._aim_point(box)
        _, _, width, height = box
        control_box = (aim_x - width * 0.5, aim_y - height * 0.5,
                       width, height)
        self.filter.update(control_box, now_ms, confidence)

    def _normalise_box(self, box):
        """Clamp one tracker box to the sensor and reject obvious drift."""
        if box is None or len(box) < 4:
            return None
        width = max(1, self.camera.width())
        height = max(1, self.camera.height())
        x, y, w, h = [int(value) for value in box[:4]]
        if w < NANO_MIN_BOX_SIDE or h < NANO_MIN_BOX_SIDE:
            return None
        if w * h > width * height * 0.88:
            return None
        x = int(clamp(x, 0, width - 1))
        y = int(clamp(y, 0, height - 1))
        w = int(clamp(w, 1, width - x))
        h = int(clamp(h, 1, height - y))
        if w < NANO_MIN_BOX_SIDE or h < NANO_MIN_BOX_SIDE:
            return None
        return x, y, w, h

    def _start_nano_tracker(self, frame, box):
        """Teach NanoTrack the already verified YOLO target."""
        if self.nano_tracker is None:
            return False
        clean = self._normalise_box(box)
        if clean is None:
            self.nano_active = False
            return False
        x, y, w, h = clean
        # NanoTrack needs a usable template even when the rocket is already
        # small. Expand only to eight pixels; a larger crop would teach sky or
        # the operator's hand instead of the rocket.
        minimum = 8
        if w < minimum:
            extra = minimum - w
            x = max(0, x - extra // 2)
            w = min(self.camera.width() - x, minimum)
        if h < minimum:
            extra = minimum - h
            y = max(0, y - extra // 2)
            h = min(self.camera.height() - y, minimum)
        try:
            self.nano_tracker.init(frame, x, y, w, h)
            self.nano_active = True
            self.nano_last_init_frame = self.frame_index
            self.nano_last_score = 1.0
            self.tracking_source = "NANO"
            return True
        except Exception as exception:
            print("NanoTrack init failed: {0}".format(exception), flush=True)
            self.nano_active = False
            return False

    def _track_with_nano(self, frame, now_ms):
        if not self.nano_active or self.nano_tracker is None:
            return None
        try:
            # Keep the call compatible with the NanoTrack binding shipped in
            # current and older MaixPy images.  We apply our stricter score
            # gate below instead of relying on an optional threshold argument.
            result = self.nano_tracker.track(frame)
        except Exception as exception:
            print("NanoTrack frame failed: {0}".format(exception), flush=True)
            self.nano_active = False
            return None
        if result is None:
            return None
        score = clamp(float(result.score), 0.0, 1.0)
        box = self._normalise_box((result.x, result.y, result.w, result.h))
        if box is None or score < NANO_MIN_SCORE:
            self.nano_last_score = score
            return None

        if self.filter.valid:
            predicted = self.filter.predict(now_ms)
            if predicted is not None:
                cx, cy = self._aim_point(box)
                distance = math.sqrt((cx - predicted[0]) ** 2 +
                                     (cy - predicted[1]) ** 2)
                diagonal = math.sqrt(self.camera.width() ** 2 +
                                     self.camera.height() ** 2)
                maximum_jump = max(diagonal * NANO_MAX_CENTRE_JUMP_RATIO,
                                   max(box[2], box[3]) * 2.8)
                if distance > maximum_jump and score < 0.82:
                    self.nano_last_score = score
                    return None
        self.nano_last_score = score
        return box, score

    def _boxes_compatible(self, first, second):
        if first is None or second is None:
            return False
        if iou(first, second) >= 0.06:
            return True
        first_x = first[0] + first[2] * 0.5
        first_y = first[1] + first[3] * 0.5
        second_x = second[0] + second[2] * 0.5
        second_y = second[1] + second[3] * 0.5
        distance = math.sqrt((first_x - second_x) ** 2 +
                             (first_y - second_y) ** 2)
        scale = max(8.0, first[2], first[3], second[2], second[3])
        return distance <= scale * 0.85

    def _update_from_nano(self, nano_result, now_ms):
        if nano_result is None:
            return False
        box, score = nano_result
        confidence = clamp(score * 0.86 + self.last_confidence * 0.14,
                           0.0, 1.0)
        self._update_motion_filter(box, now_ms, confidence)
        self.last_box = box
        self.last_confidence = confidence
        self.missing_frames = 0
        self.lost_started_ms = 0
        self.confirm_count = LOCK_CONFIRM_FRAMES
        self.has_ever_locked = True
        self.tracking_source = "NANO"
        # NanoTrack is excellent at motion continuity but can drift onto a hand,
        # reflection or nearby object.  It may command LOCK only while YOLO has
        # semantically confirmed the same box very recently.
        yolo_recent = self.frame_index - self.last_yolo_lock_frame <= 8
        manual_object = self.identity_is_manual and bool(self.appearance_templates)
        self.state = (STATE_LOCKED if (yolo_recent or manual_object) and
                      score >= NANO_STRONG_SCORE else STATE_WEAK)
        return True

    def _detections_to_tracks(self, objects, universal=False):
        converted = []
        for obj in objects:
            if not universal:
                if self.enrollment_class_id >= 0:
                    if obj.class_id != self.enrollment_class_id:
                        continue
                elif obj.class_id not in self.valid_class_ids:
                    continue
            converted.append(tracker.Object(
                obj.x, obj.y, obj.w, obj.h, obj.class_id, obj.score
            ))
        return self.byte_tracker.update(converted)

    def _candidate_score(self, track_item, now_ms, frame):
        obj = track_item.history[-1]
        box = (obj.x, obj.y, obj.w, obj.h)
        raw_confidence = clamp(track_item.score, 0.0, 1.0)
        camera_width = max(1.0, float(self.camera.width()))
        camera_height = max(1.0, float(self.camera.height()))
        cx, cy = obj.x + obj.w * 0.5, obj.y + obj.h * 0.5
        aim_x, aim_y = self._aim_point(box)

        # A new session begins with the object deliberately placed near the
        # centre.  Use that fact only while acquiring; once locked, identity,
        # IoU and the motion prediction become the authority.  The old formula
        # could never acquire a detector score below ~0.65 even though the
        # detector itself intentionally accepts scores down to 0.16.
        if self.target_id == -1 or not self.filter.valid:
            nx = (cx - camera_width * 0.5) / (camera_width * 0.5)
            ny = (cy - camera_height * 0.5) / (camera_height * 0.5)
            centre_distance = math.sqrt(nx * nx + ny * ny) / math.sqrt(2.0)
            centre_prior = clamp(1.0 - centre_distance * 1.25, 0.0, 1.0)
            area_ratio = obj.w * obj.h / (camera_width * camera_height)
            visible_prior = clamp(min(obj.w / camera_width,
                                      obj.h / camera_height) * 9.0, 0.0, 1.0)
            not_full_frame = clamp((0.88 - area_ratio) / 0.38, 0.0, 1.0)
            size_prior = visible_prior * not_full_frame
            if self.has_ever_locked:
                # After a complete disappearance the rocket may re-enter at an
                # edge.  The custom detector class and two-frame confirmation
                # are stronger evidence than the initial centre placement.
                appearance = self._appearance_similarity(
                    self._appearance_signature(frame, box)
                )
                if appearance is not None:
                    colour_gate = 0.42 if self.active_mode == "PERSON" else 0.35
                    if appearance < colour_gate and raw_confidence < 0.72:
                        return 0.0, box
                    return (raw_confidence * 0.45 + appearance * 0.43 +
                            centre_prior * 0.02 + size_prior * 0.10), box
                return (raw_confidence * 0.82 + centre_prior * 0.08 +
                        size_prior * 0.10), box
            return (raw_confidence * 0.68 + centre_prior * 0.22 +
                    size_prior * 0.10), box

        score = raw_confidence * 0.28
        appearance = None
        if self.appearance_template is not None or self.appearance_templates:
            appearance = self._appearance_similarity(
                self._appearance_signature(frame, box)
            )
            if appearance is not None:
                colour_gate = 0.40 if self.active_mode == "PERSON" else 0.34
                if appearance < colour_gate and raw_confidence < 0.74:
                    return 0.0, box
                score += appearance * 0.34
        if track_item.id == self.target_id:
            score += 0.26
        if self.last_box is not None:
            overlap = iou(box, self.last_box)
            score += overlap * 0.10
            old_area = max(1.0, self.last_box[2] * self.last_box[3])
            new_area = max(1.0, obj.w * obj.h)
            score += (min(old_area, new_area) / max(old_area, new_area)) * 0.05
        predicted = self.filter.predict(now_ms)
        if predicted is not None:
            px, py, _, _ = predicted
            diagonal = math.sqrt(camera_width ** 2 + camera_height ** 2)
            distance = math.sqrt((aim_x - px) ** 2 +
                                 (aim_y - py) ** 2) / max(1.0, diagonal)
            score += clamp(1.0 - distance * 4.5, 0.0, 1.0) * 0.16
        return score, box

    def _select_target(self, tracks, now_ms, frame):
        best = None
        best_score = -1.0
        best_box = None
        for track_item in tracks:
            if track_item.lost or not track_item.history:
                continue
            candidate_score, box = self._candidate_score(track_item, now_ms, frame)
            if candidate_score > best_score:
                best = track_item
                best_score = candidate_score
                best_box = box
        if self.target_id == -1 or not self.filter.valid:
            minimum_score = (REACQUIRE_SCORE_MIN if self.has_ever_locked
                             else ACQUIRE_SCORE_MIN)
        else:
            minimum_score = ASSOCIATE_SCORE_MIN
        if best is None or best_score < minimum_score:
            return None
        return best, best_box, best_score

    def _select_enrollment_candidate(self, tracks):
        width = max(1.0, float(self.camera.width()))
        height = max(1.0, float(self.camera.height()))
        best = None
        best_score = -1.0
        for track_item in tracks:
            if track_item.lost or not track_item.history:
                continue
            obj = track_item.history[-1]
            cx = obj.x + obj.w * 0.5
            cy = obj.y + obj.h * 0.5
            nx = (cx - width * 0.5) / (width * 0.5)
            ny = (cy - height * 0.5) / (height * 0.5)
            centre_distance = math.sqrt(nx * nx + ny * ny) / math.sqrt(2.0)
            centre_prior = clamp(1.0 - centre_distance * 1.65, 0.0, 1.0)
            area = clamp(obj.w * obj.h / (width * height) * 7.0, 0.0, 1.0)
            score = clamp(track_item.score, 0.0, 1.0) * 0.58 + centre_prior * 0.34 + area * 0.08
            if score > best_score:
                best = track_item
                best_score = score
        return best

    def _restart_enrollment(self, now_ms):
        self.enrolling = True
        self.enroll_started_ms = now_ms
        self.enroll_last_report_ms = 0
        self.enroll_total_frames = 0
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self.enroll_next_proposal_id = -1
        self.awaiting_selection = False
        self.selection_candidates = {}
        self.selection_order = []
        self.candidate_report_index = 0
        self.choose_last_report_ms = 0
        self.refining = False
        self.refine_manual = False
        self.selected_candidate_slot = -1
        self.selected_waiting_center = False
        self.identity_is_manual = False
        self.target_id = -1
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.enrollment_class_id = -1
        self.appearance_template = None
        self.appearance_templates = []
        self.last_box = None
        self.last_confidence = 0.0
        self.filter.reset()
        self.nano_active = False
        self.state = STATE_ACQUIRE
        self._write("E,0,{0},RETRY".format(self.active_mode))

    def _update_enrollment(self, objects, frame, now_ms):
        """Collect tappable objects without trusting unstable ByteTrack IDs.

        With two alternating detectors a stationary object can receive a new
        ByteTrack ID on every sighting. Spatial clustering keeps that object as
        one proposal, so one valid detection is enough to appear after 3 s.
        """
        self.enroll_total_frames += 1
        for detected in objects:
            box = (float(detected.x), float(detected.y),
                   float(detected.w), float(detected.h))
            if box[2] < 4 or box[3] < 4:
                continue
            confidence = clamp(float(detected.score), 0.0, 1.0)
            class_id = int(detected.class_id)
            target_id = None
            best_match = 0.0
            cx = box[0] + box[2] * 0.5
            cy = box[1] + box[3] * 0.5
            area = max(1.0, box[2] * box[3])
            for proposal_id, saved in self.enroll_last_seen.items():
                old_box, old_confidence, old_class = saved
                old_cx = old_box[0] + old_box[2] * 0.5
                old_cy = old_box[1] + old_box[3] * 0.5
                distance = math.sqrt((cx - old_cx) ** 2 + (cy - old_cy) ** 2)
                scale = max(10.0, box[2], box[3], old_box[2], old_box[3])
                proximity = clamp(1.0 - distance / scale, 0.0, 1.0)
                old_area = max(1.0, old_box[2] * old_box[3])
                size_ratio = min(area, old_area) / max(area, old_area)
                overlap = iou(box, old_box)
                class_compatible = class_id == old_class or overlap >= 0.55
                if (not class_compatible or size_ratio < 0.22 or
                        (overlap < 0.16 and proximity < 0.48)):
                    continue
                match = max(overlap, proximity * size_ratio)
                if match > best_match:
                    best_match = match
                    target_id = proposal_id

            if target_id is None:
                target_id = self.enroll_next_proposal_id
                self.enroll_next_proposal_id -= 1
                merged_box = box
                merged_confidence = confidence
                merged_class = class_id
            else:
                old_box, old_confidence, old_class = self.enroll_last_seen[target_id]
                alpha = 0.48 if self.enroll_votes.get(target_id, 0) < 3 else 0.30
                merged_box = tuple(
                    old_box[index] * (1.0 - alpha) + box[index] * alpha
                    for index in range(4)
                )
                merged_confidence = max(confidence, old_confidence * 0.92)
                merged_class = old_class
                if (class_id == CUSTOM_ROCKET_CLASS_ID or
                        confidence > old_confidence + 0.08):
                    merged_class = class_id

            self.enroll_votes[target_id] = self.enroll_votes.get(target_id, 0) + 1
            self.enroll_last_seen[target_id] = (
                merged_box, merged_confidence, merged_class
            )
            if self.frame_index % 3 == 0:
                signature = self._appearance_signature(frame, merged_box)
                if signature is not None:
                    if target_id not in self.enroll_signature_sums:
                        self.enroll_signature_sums[target_id] = [0.0] * len(signature)
                        self.enroll_signature_counts[target_id] = 0
                    sums = self.enroll_signature_sums[target_id]
                    for index, value in enumerate(signature):
                        sums[index] += value
                    self.enroll_signature_counts[target_id] += 1

        elapsed = ticks_delta(now_ms, self.enroll_started_ms)
        progress = int(clamp(elapsed * 100.0 / ENROLL_DURATION_MS, 0, 100))
        if (self.enroll_last_report_ms == 0 or
                ticks_delta(now_ms, self.enroll_last_report_ms) >= ENROLL_REPORT_INTERVAL_MS):
            self._write("E,{0},{1},SCANNING".format(progress, self.active_mode))
            self.enroll_last_report_ms = now_ms
        if elapsed < ENROLL_DURATION_MS:
            return

        # End after exactly one scan. If YOLO does not know the object, the
        # iPhone opens point-selection mode instead of restarting forever.
        if not self.enroll_votes:
            self.enrolling = False
            self.awaiting_selection = True
            self.state = STATE_ACQUIRE
            self.selection_candidates = {}
            self.selection_order = []
            self._emit_candidates(now_ms, True)
            print("Candidate selection ready: manual point fallback", flush=True)
            return

        ranked = []
        for target_id, votes in self.enroll_votes.items():
            if target_id not in self.enroll_last_seen:
                continue
            box, confidence, class_id = self.enroll_last_seen[target_id]
            visible_ratio = votes / float(max(1, self.enroll_total_frames))
            if visible_ratio < ENROLL_MIN_VISIBLE_RATIO:
                continue
            area_ratio = box[2] * box[3] / float(
                max(1, self.camera.width() * self.camera.height())
            )
            rank_score = visible_ratio * 0.62 + confidence * 0.30 + min(0.08, area_ratio)
            ranked.append((rank_score, target_id))
        ranked.sort(reverse=True)
        # The custom rocket detector and COCO can describe the same pixels.
        # Keep one stable box per physical subject so every visible object is
        # tappable without stacking two buttons on top of each other.
        deduplicated = []
        for ranked_item in ranked:
            candidate_box = self.enroll_last_seen[ranked_item[1]][0]
            if any(iou(candidate_box,
                       self.enroll_last_seen[saved[1]][0]) >= 0.68
                   for saved in deduplicated):
                continue
            deduplicated.append(ranked_item)
            if len(deduplicated) >= MAX_SELECTION_CANDIDATES:
                break
        ranked = deduplicated
        if not ranked:
            self.enrolling = False
            self.awaiting_selection = True
            self.state = STATE_ACQUIRE
            self.selection_candidates = {}
            self.selection_order = []
            self._emit_candidates(now_ms, True)
            print("Candidate selection ready: filtered point fallback", flush=True)
            return

        self.enrolling = False
        self.awaiting_selection = True
        self.state = STATE_ACQUIRE
        self.selection_candidates = {}
        self.selection_order = []
        for slot, ranked_item in enumerate(ranked, 1):
            target_id = ranked_item[1]
            box, confidence, class_id = self.enroll_last_seen[target_id]
            signature = None
            signature_count = self.enroll_signature_counts.get(target_id, 0)
            if signature_count > 0 and target_id in self.enroll_signature_sums:
                signature = [
                    value / signature_count
                    for value in self.enroll_signature_sums[target_id]
                ]
            self.selection_candidates[slot] = {
                "track_id": target_id,
                "box": box,
                "confidence": confidence,
                "class_id": class_id,
                # Selection proposals are spatial ROIs. NanoTrack owns their
                # identity after the tap, independent of detector ID changes.
                "manual": True,
                "label": candidate_label(class_id),
                "signature": signature,
            }
            self.selection_order.append(slot)
        self._emit_candidates(now_ms, True)
        print("Candidate selection ready: mode={0} count={1}".format(
            self.active_mode, len(self.selection_order)
        ), flush=True)

    def _emit_candidate_slot(self, slot):
        candidate = self.selection_candidates.get(slot)
        if candidate is None:
            return
        width = max(1.0, float(self.camera.width()))
        height = max(1.0, float(self.camera.height()))
        x, y, w, h = candidate["box"]
        cx = int(clamp((x + w * 0.5) / width * 1000.0, 0, 1000))
        cy = int(clamp((y + h * 0.5) / height * 1000.0, 0, 1000))
        bw = int(clamp(w / width * 1000.0, 0, 1000))
        bh = int(clamp(h / height * 1000.0, 0, 1000))
        confidence = int(clamp(candidate["confidence"] * 100.0, 0, 100))
        label = candidate.get("label", candidate_label(candidate["class_id"]))
        self._write("D,{0},{1},{2},{3},{4},{5},{6},{7},{8}".format(
            slot, candidate["track_id"], candidate["class_id"], confidence,
            cx, cy, bw, bh, label
        ))

    def _emit_candidates(self, now_ms, force=False):
        # CHOOSE is a state transition, not a one-shot packet. Repeating it
        # prevents BLE/UART loss without letting an early candidate packet make
        # the iPhone leave the full three-second scan prematurely.
        if force:
            self._write("E,100,{0},CHOOSE,{1}".format(
                self.active_mode, len(self.selection_order)
            ))
            self.choose_last_report_ms = now_ms
        else:
            # Candidate boxes are a frozen snapshot. Do not continuously fill
            # the UART while waiting for the user's tap; SELECT/STOP must have
            # immediate access to the receive side.
            return
        if not self.selection_order:
            return
        if force:
            # Send the complete snapshot immediately. The ESP32 queue has room
            # for all 12 candidates; later packets repeat one slot at a time for
            # reliability and live movement updates.
            for slot in self.selection_order:
                self._emit_candidate_slot(slot)
            self.candidate_report_index = 0
            self.candidate_last_report_ms = now_ms
            return
        self.candidate_report_index %= len(self.selection_order)
        slot = self.selection_order[self.candidate_report_index]
        self.candidate_report_index = (self.candidate_report_index + 1) % len(self.selection_order)
        self._emit_candidate_slot(slot)
        self.candidate_last_report_ms = now_ms

    def _update_selection_candidates(self, tracks, now_ms):
        # Keep each slot attached to the ByteTrack identity captured during the
        # 3-second scan. Boxes now follow slow hand/object motion while the user
        # chooses, instead of remaining stuck on the old snapshot.
        live_by_id = {}
        for track_item in tracks:
            if track_item.lost or not track_item.history:
                continue
            live_by_id[track_item.id] = track_item
        for slot in self.selection_order:
            candidate = self.selection_candidates.get(slot)
            if candidate is None:
                continue
            track_item = live_by_id.get(candidate["track_id"])
            if track_item is None:
                continue
            obj = track_item.history[-1]
            old_x, old_y, old_w, old_h = candidate["box"]
            alpha = 0.70
            candidate["box"] = (
                old_x * (1.0 - alpha) + obj.x * alpha,
                old_y * (1.0 - alpha) + obj.y * alpha,
                old_w * (1.0 - alpha) + obj.w * alpha,
                old_h * (1.0 - alpha) + obj.h * alpha,
            )
            candidate["confidence"] = clamp(
                candidate["confidence"] * 0.35 + track_item.score * 0.65,
                0.0, 1.0
            )
        self._emit_candidates(now_ms)

    def _select_candidate(self, slot, now_ms):
        # SELECT is retried by the iPhone until its BLE acknowledgement arrives.
        # A selection only chooses an identity. Refinement intentionally waits
        # until the user puts that same identity on the iPhone '+' and presses
        # Căn tâm.
        if (self.enabled and self.selected_candidate_slot == slot and
                (self.selected_waiting_center or self.refining)):
            return True
        if not self.enabled or not self.awaiting_selection:
            return False
        candidate = self.selection_candidates.get(slot)
        if candidate is None:
            self._emit_candidates(now_ms, True)
            return False
        self.awaiting_selection = False
        self.selected_waiting_center = True
        self.refining = False
        self.selected_candidate_slot = slot
        self.identity_is_manual = True
        self.refine_manual = True
        self.target_id = candidate["track_id"]
        raw_class_id = candidate["class_id"]
        self.enrollment_class_id = (0 if raw_class_id == CUSTOM_ROCKET_CLASS_ID
                                    else raw_class_id)
        self.locked_label = ("WATER_ROCKET" if self.active_mode == "ROCKET"
                             else candidate.get("label", self.active_mode))
        self.last_box = candidate["box"]
        self.last_confidence = candidate["confidence"]
        selected_signature = candidate.get("signature")
        if selected_signature is not None:
            self.appearance_template = list(selected_signature)
            self.appearance_templates = [list(selected_signature)]
        self.filter.reset()
        self.nano_active = False
        self.state = STATE_ACQUIRE
        self._write("E,100,{0},SELECTED,{1}".format(
            self.active_mode, self.locked_label
        ))
        print("Candidate selected; waiting for iPhone centre: slot={0} id={1}".format(
            slot, self.target_id
        ), flush=True)
        return True

    def _select_manual_point(self, point_x, point_y, now_ms):
        """Create a real local ROI when YOLO has no class for the tapped item."""
        if (not self.enabled or not self.awaiting_selection or
                point_x < 0 or point_x > 1000 or point_y < 0 or point_y > 1000):
            return False
        width = float(max(1, self.camera.width()))
        height = float(max(1, self.camera.height()))
        if self.active_mode == "PERSON":
            box_w, box_h = width * 0.20, height * 0.34
        elif self.active_mode == "ROCKET":
            box_w, box_h = width * 0.16, height * 0.28
        elif self.active_mode == "ANIMAL":
            box_w, box_h = width * 0.25, height * 0.24
        else:
            box_w, box_h = width * 0.22, height * 0.22
        center_x = point_x / 1000.0 * width
        center_y = point_y / 1000.0 * height
        box = (
            clamp(center_x - box_w * 0.5, 0, width - box_w),
            clamp(center_y - box_h * 0.5, 0, height - box_h),
            box_w, box_h,
        )
        self.selection_candidates = {
            0: {
                "track_id": -1000,
                "box": box,
                "confidence": 0.55,
                "class_id": -1,
                "manual": True,
                "label": self.active_mode,
                "signature": None,
            }
        }
        self.selection_order = [0]
        return self._select_candidate(0, now_ms)

    def _begin_refinement(self, slot, now_ms):
        if self.enabled and self.refining and self.selected_candidate_slot == slot:
            return True
        if (not self.enabled or not self.selected_waiting_center or
                slot != self.selected_candidate_slot):
            return False
        self.selected_waiting_center = False
        self.refining = True
        self.refine_started_ms = now_ms
        self.refine_last_report_ms = 0
        self.refine_total_frames = 0
        self.refine_visible_frames = 0
        self.refine_signature_sum = None
        self.refine_signature_count = 0
        # Keep every previously learned view. The new three-second pass adds
        # information to a reused profile; it must never collapse eight saved
        # views into one current camera angle.
        self.refine_signatures = [list(signature)
                                  for signature in self.appearance_templates]
        if not self.refine_signatures and self.appearance_template is not None:
            self.refine_signatures = [list(self.appearance_template)]
        self._write("E,0,{0},REFINE,{1}".format(
            self.active_mode, self.locked_label
        ))
        print("Refining selected candidate: slot={0} id={1}".format(
            slot, self.target_id
        ), flush=True)
        return True

    def _update_selected_waiting(self, frame, now_ms):
        """Follow the chosen identity while the user moves it onto iPhone '+'."""
        if self.last_box is None:
            return
        if not self.nano_active:
            self._start_nano_tracker(frame, self.last_box)
        nano_result = self._track_with_nano(frame, now_ms)
        if nano_result is None:
            return
        box, confidence = nano_result
        self.last_box = box
        self.last_confidence = confidence
        self._update_motion_filter(box, now_ms, confidence)

    def _update_refinement(self, tracks, frame, now_ms):
        self.refine_total_frames += 1
        captured = None
        if self.refine_manual:
            if not self.nano_active and self.last_box is not None:
                self._start_nano_tracker(frame, self.last_box)
            nano_result = self._track_with_nano(frame, now_ms)
            if nano_result is not None:
                captured = nano_result
            elif self.last_box is not None:
                # Transparent PET can have too little texture for NanoTrack in
                # the first frames. During the short refinement step the user
                # holds it still, so retain the chosen frozen box long enough
                # to learn its colour/edge signature instead of restarting the
                # full 3-second scan.
                captured = (self.last_box, max(0.45, self.last_confidence))
        else:
            selected = None
            for track_item in tracks:
                if track_item.lost or not track_item.history:
                    continue
                obj = track_item.history[-1]
                if obj.class_id != self.enrollment_class_id:
                    continue
                box = (obj.x, obj.y, obj.w, obj.h)
                if track_item.id == self.target_id:
                    selected = track_item
                    break
                if (self.last_box is not None and
                        self._boxes_compatible(box, self.last_box)):
                    selected = track_item
            if selected is not None:
                obj = selected.history[-1]
                self.target_id = selected.id
                captured = ((obj.x, obj.y, obj.w, obj.h),
                            clamp(selected.score, 0.0, 1.0))

        if captured is not None:
            box, confidence = captured
            self.last_box = box
            self.last_confidence = confidence
            self._update_motion_filter(box, now_ms, confidence)
            self.refine_visible_frames += 1
            signature = self._appearance_signature(frame, box)
            if signature is not None:
                if self.refine_signature_sum is None:
                    self.refine_signature_sum = [0.0] * len(signature)
                for index, value in enumerate(signature):
                    self.refine_signature_sum[index] += value
                self.refine_signature_count += 1
                if (not self.refine_signatures or
                        min(self._signature_distance(signature, saved)
                            for saved in self.refine_signatures) >=
                        APPEARANCE_DIVERSITY_MIN):
                    if len(self.refine_signatures) < APPEARANCE_TEMPLATE_LIMIT:
                        self.refine_signatures.append(list(signature))

        elapsed = ticks_delta(now_ms, self.refine_started_ms)
        progress = int(clamp(elapsed * 100.0 / REFINE_DURATION_MS, 0, 100))
        if (self.refine_last_report_ms == 0 or
                ticks_delta(now_ms, self.refine_last_report_ms) >= ENROLL_REPORT_INTERVAL_MS):
            self._write("E,{0},{1},REFINE,{2}".format(
                progress, self.active_mode, self.locked_label
            ))
            self.refine_last_report_ms = now_ms
        if elapsed < REFINE_DURATION_MS:
            return

        visible_ratio = self.refine_visible_frames / float(max(1, self.refine_total_frames))
        # Refinement is a bounded setup step, never a hidden route back to the
        # three-second scan. Transparent PET can briefly defeat NanoTrack; in
        # that case retain the exact ROI chosen by the user and finish anyway.
        if self.last_box is None:
            width = float(max(1, self.camera.width()))
            height = float(max(1, self.camera.height()))
            self.last_box = (width * 0.42, height * 0.36,
                             width * 0.16, height * 0.28)
            self.last_confidence = 0.45
        if not self.filter.valid:
            self._update_motion_filter(
                self.last_box, now_ms, max(0.45, self.last_confidence)
            )
        if self.refine_signature_count > 0:
            current_average = [
                value / self.refine_signature_count
                for value in self.refine_signature_sum
            ]
            merged_templates = [current_average]
            for signature in self.refine_signatures:
                if len(merged_templates) >= APPEARANCE_TEMPLATE_LIMIT:
                    break
                if min(self._signature_distance(signature, saved)
                       for saved in merged_templates) >= APPEARANCE_DIVERSITY_MIN * 0.45:
                    merged_templates.append(signature)
            self.appearance_templates = merged_templates
            self.appearance_template = list(merged_templates[0])
        self.refining = False
        self.selected_waiting_center = False
        self.selection_candidates = {}
        self.selection_order = []
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = True
        self.confirm_count = LOCK_CONFIRM_FRAMES
        self.missing_frames = 0
        self.last_yolo_frame = self.frame_index
        self.last_yolo_lock_frame = self.frame_index
        self._start_nano_tracker(frame, self.last_box)
        self.state = STATE_LOCKED
        self._write("E,100,{0},READY,{1}".format(
            self.active_mode, self.locked_label
        ))
        # Reusing a saved identity learns the current view for three seconds,
        # then refreshes that same flash profile automatically.
        if self.active_profile_slot > 0:
            self._save_profile(self.active_profile_slot)
        print("Selected subject memorised: mode={0} id={1} visible={2:.0f}%".format(
            self.active_mode, self.target_id, visible_ratio * 100.0
        ), flush=True)

    def _begin_multiview(self, now_ms):
        if self.enabled and self.multiview_active:
            return True
        if not self.enabled or self.last_box is None:
            return False
        self.multiview_active = True
        self.multiview_started_ms = now_ms
        self.multiview_last_report_ms = 0
        self.multiview_signatures = []
        self._write("V,0,{0},CAPTURE,{1}".format(
            self.active_mode, self.locked_label
        ))
        print("Multi-view learning started: rotate/tilt selected subject",
              flush=True)
        return True

    def _update_multiview(self, frame, now_ms):
        """Learn several views for three seconds without recording a movie."""
        nano_result = self._track_with_nano(frame, now_ms)
        selected = None
        yolo_due = (nano_result is None or self.state != STATE_LOCKED or
                    self.frame_index - self.last_yolo_frame >= 5)
        if yolo_due:
            bottle_identity = (self.active_mode == "ROCKET" and
                               self.enrollment_class_id == 39)
            objects = self._detect_objects(
                frame,
                include_bottle=bottle_identity,
                bottle_only=bottle_identity,
            )
            self.last_yolo_frame = self.frame_index
            tracks = self._detections_to_tracks(objects)
            selected = self._select_target(tracks, now_ms, frame)

        if selected is not None:
            self._update_target(selected, now_ms)
            self.tracking_source = "YOLO"
            if self.state == STATE_LOCKED:
                self.last_yolo_lock_frame = self.frame_index
                if nano_result is None or not self.nano_active:
                    self._start_nano_tracker(frame, selected[1])
        elif not self._update_from_nano(nano_result, now_ms):
            self._update_target(None, now_ms)

        if (self.last_box is not None and
                self.state in (STATE_LOCKED, STATE_WEAK) and
                self.frame_index % 2 == 0):
            signature = self._appearance_signature(frame, self.last_box)
            if signature is not None:
                all_templates = self.appearance_templates + self.multiview_signatures
                if (not all_templates or
                        min(self._signature_distance(signature, saved)
                            for saved in all_templates) >=
                        MULTIVIEW_DIVERSITY_MIN):
                    self.multiview_signatures.append(list(signature))

        elapsed = ticks_delta(now_ms, self.multiview_started_ms)
        progress = int(clamp(
            elapsed * 100.0 / MULTIVIEW_DURATION_MS, 0, 100
        ))
        if (self.multiview_last_report_ms == 0 or
                ticks_delta(now_ms, self.multiview_last_report_ms) >=
                MULTIVIEW_REPORT_INTERVAL_MS):
            self._write("V,{0},{1},CAPTURE,{2}".format(
                progress, self.active_mode, self.locked_label
            ))
            self.multiview_last_report_ms = now_ms
        if elapsed < MULTIVIEW_DURATION_MS:
            return

        if not self.appearance_templates and self.appearance_template is not None:
            self.appearance_templates = [list(self.appearance_template)]
        for signature in self.multiview_signatures:
            if len(self.appearance_templates) >= APPEARANCE_TEMPLATE_LIMIT:
                break
            self.appearance_templates.append(signature)
        if self.appearance_templates:
            self.appearance_template = list(self.appearance_templates[0])
        self.multiview_active = False
        self._write("V,100,{0},READY,{1}".format(
            self.active_mode, self.locked_label
        ))
        print("Multi-view learning complete: {0} identity views".format(
            len(self.appearance_templates)
        ), flush=True)

    def _update_target(self, selected, now_ms):
        if selected is None:
            self.missing_frames += 1
            self.confirm_count = 0
            self.pending_target_id = -1
            self.pending_target_frames = 0
            if self.lost_started_ms == 0:
                self.lost_started_ms = now_ms
            memory_elapsed = ticks_delta(now_ms, self.lost_started_ms)
            if self.filter.valid and memory_elapsed <= REACQUIRE_MEMORY_MS:
                self.filter.coast(now_ms)
                self.state = STATE_WEAK if self.missing_frames < LOST_AFTER_FRAMES else STATE_LOST
            else:
                self.state = STATE_ACQUIRE
                self.target_id = -1
                self.filter.reset()
                self.nano_active = False
            self.last_confidence *= 0.83
            return

        track_item, box, association_score = selected
        confidence = clamp(track_item.score * 0.45 + association_score * 0.55,
                           0.0, 1.0)

        if self.target_id == -1:
            if track_item.id == self.pending_target_id:
                self.pending_target_frames += 1
            else:
                self.pending_target_id = track_item.id
                self.pending_target_frames = 1
                self.filter.reset()
            self._update_motion_filter(box, now_ms, confidence)
            self.last_box = box
            self.last_confidence = confidence
            self.missing_frames = 0
            self.lost_started_ms = 0
            required_frames = (1 if self.has_ever_locked and
                               association_score >= FAST_REACQUIRE_SCORE
                               else LOCK_CONFIRM_FRAMES)
            if self.pending_target_frames >= required_frames:
                self.target_id = track_item.id
                self.pending_target_id = -1
                self.pending_target_frames = 0
                self.confirm_count = LOCK_CONFIRM_FRAMES
                self.has_ever_locked = True
                self.state = STATE_LOCKED
            else:
                self.confirm_count = self.pending_target_frames
                self.state = STATE_ACQUIRE
            return

        if track_item.id != self.target_id:
            # Never jump to a different ByteTrack identity from one frame.  Keep
            # coasting the old trajectory while the replacement is confirmed.
            if track_item.id == self.pending_target_id:
                self.pending_target_frames += 1
            else:
                self.pending_target_id = track_item.id
                self.pending_target_frames = 1
            required_frames = (1 if self.has_ever_locked and
                               association_score >= FAST_REACQUIRE_SCORE
                               else LOCK_CONFIRM_FRAMES)
            if self.pending_target_frames < required_frames:
                self.missing_frames += 1
                self.filter.coast(now_ms)
                self.last_confidence *= 0.90
                self.state = STATE_WEAK
                return
            self.target_id = track_item.id
            self.pending_target_id = -1
            self.pending_target_frames = 0
            self.filter.reset()

        self.confirm_count = LOCK_CONFIRM_FRAMES
        self._update_motion_filter(box, now_ms, confidence)
        self.last_box = box
        self.last_confidence = confidence
        self.missing_frames = 0
        self.lost_started_ms = 0
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = True
        self.state = STATE_LOCKED

    def _send_target(self, now_ms):
        # The setup states can run much faster than neural inference. Without a
        # rate limit they flooded UART with ~1000 empty target packets/second,
        # blocking SELECT, REFINE and STOP commands after the 3-second scan.
        if ticks_delta(now_ms, self.last_target_report_ms) < TARGET_REPORT_INTERVAL_MS:
            return
        self.last_target_report_ms = now_ms
        # ESP32 already knows setup is active from E packets and holds both
        # servos. Do not send meaningless 500,500 target packets during scan,
        # selection or refinement; on MaixCAM's UART driver those writes can
        # starve the receive side that carries SELECT/REFINE/STOP.
        if (self.enabled and (self.enrolling or self.awaiting_selection or
                             self.selected_waiting_center or self.refining or
                             self.multiview_active)):
            return
        self.sequence = (self.sequence + 1) & 0xFFFF
        if not self.enabled or not self.filter.valid:
            payload = "T,{0},{1},500,500,0,0,0,0,0,{2}".format(
                self.sequence, now_ms, self.state
            )
            self._write(payload)
            return

        width = max(1, self.camera.width())
        height = max(1, self.camera.height())
        cx = int(clamp(self.filter.cx / width * 1000.0, 0, 1000))
        cy = int(clamp(self.filter.cy / height * 1000.0, 0, 1000))
        # Send the real filtered target size. ESP32 uses it to schedule servo
        # gain: a tiny distant rocket needs a faster response than a large
        # nearby object. The iPhone still draws a fixed 5 mm aim reticle.
        bw = int(clamp(self.filter.w / width * 1000.0, 4, 1000))
        bh = int(clamp(self.filter.h / height * 1000.0, 4, 1000))
        conf = int(clamp(self.last_confidence * 100.0, 0, 100))
        vx = int(clamp(self.filter.vx / width * 1000.0, -2500, 2500))
        vy = int(clamp(self.filter.vy / height * 1000.0, -2500, 2500))
        payload = "T,{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}".format(
            self.sequence, now_ms, cx, cy, bw, bh, conf, vx, vy, self.state
        )
        self._write(payload)

    def _run_enabled_frame(self, frame, now_ms):
        """Fuse semantic YOLO detections with low-latency single-object tracking."""
        if self.enrolling:
            objects = self._detect_enrollment_objects(frame)
            self.last_yolo_frame = self.frame_index
            self._update_enrollment(objects, frame, now_ms)
            return

        if self.awaiting_selection:
            # Keep the complete scan snapshot stable under the user's finger.
            # Re-running YOLO here wastes FPS and can renumber the boxes.
            self._emit_candidates(now_ms)
            return

        if self.selected_waiting_center:
            self._update_selected_waiting(frame, now_ms)
            return

        if self.refining:
            if self.refine_manual:
                tracks = []
            else:
                objects = self._detect_objects(frame)
                self.last_yolo_frame = self.frame_index
                tracks = self._detections_to_tracks(objects)
            self._update_refinement(tracks, frame, now_ms)
            return

        if self.multiview_active:
            self._update_multiview(frame, now_ms)
            return

        nano_result = self._track_with_nano(frame, now_ms)
        yolo_interval = (YOLO_ROCKET_INTERVAL if self.active_mode == "ROCKET"
                         else YOLO_GENERAL_INTERVAL)
        yolo_due = (nano_result is None or self.state != STATE_LOCKED or
                    self.frame_index - self.last_yolo_frame >= yolo_interval)
        selected = None
        if yolo_due:
            bottle_identity = (self.active_mode == "ROCKET" and
                               self.enrollment_class_id == 39)
            objects = self._detect_objects(
                frame,
                include_bottle=bottle_identity,
                bottle_only=bottle_identity,
            )
            self.last_yolo_frame = self.frame_index
            tracks = self._detections_to_tracks(objects)
            selected = self._select_target(tracks, now_ms, frame)

        if (selected is not None and nano_result is not None and
                self.state == STATE_LOCKED and
                nano_result[1] >= NANO_STRONG_SCORE and
                not self._boxes_compatible(nano_result[0], selected[1])):
            # Never jump from a healthy single-object track to an unrelated
            # YOLO detection in one frame. Once lock is weak/lost, however,
            # appearance-verified YOLO must be allowed to take over immediately
            # or a stale NanoTrack box can block reacquisition indefinitely.
            selected = None

        if selected is not None:
            yolo_box = selected[1]
            association_score = selected[2]
            self._update_target(selected, now_ms)
            self.tracking_source = "YOLO"
            if self.state == STATE_LOCKED:
                self.last_yolo_lock_frame = self.frame_index
                periodic_refresh = (
                    self.frame_index - self.nano_last_init_frame >=
                    NANO_REINIT_FRAMES
                )
                # Re-teach scale/pose periodically, but never let one unrelated
                # YOLO box overwrite a healthy NanoTrack identity.
                if (not self.nano_active or
                        (periodic_refresh and nano_result is not None) or
                        (nano_result is None and association_score >= 0.58)):
                    self._start_nano_tracker(frame, yolo_box)
            return

        if self._update_from_nano(nano_result, now_ms):
            return

        self._update_target(None, now_ms)

    def _draw_preview(self, frame):
        width, height = frame.width(), frame.height()
        color = image.COLOR_GREEN if self.state == STATE_LOCKED else image.COLOR_YELLOW
        frame.draw_cross(width // 2, height // 2, color=image.COLOR_WHITE, size=8, thickness=1)
        if self.awaiting_selection:
            for slot in self.selection_order:
                candidate = self.selection_candidates.get(slot)
                if candidate is None:
                    continue
                x, y, w, h = candidate["box"]
                frame.draw_rect(int(x), int(y), int(w), int(h),
                                color=image.COLOR_BLUE, thickness=2)
                frame.draw_string(int(x), max(2, int(y) - 14), str(slot),
                                  color=image.COLOR_BLUE, scale=1.0)
        if self.filter.valid:
            aim_side = max(8, int(min(width, height) * 0.05))
            x = int(self.filter.cx - aim_side * 0.5)
            y = int(self.filter.cy - aim_side * 0.5)
            frame.draw_rect(x, y, aim_side, aim_side, color=color, thickness=2)
            frame.draw_cross(int(self.filter.cx), int(self.filter.cy), color=color, size=5, thickness=2)
        label = "SE {0} {1}/{2} {3}% {4:.1f}fps".format(
            self.locked_label,
            ("3S" if self.enrolling else "CHOOSE" if self.awaiting_selection
             else "REFINE" if self.refining
             else "VIEWS" if self.multiview_active
             else "LOCK" if self.state == STATE_LOCKED else "FIND"),
            self.tracking_source,
            int(self.last_confidence * 100),
            self.fps,
        )
        frame.draw_string(4, 4, label, color=image.COLOR_WHITE, scale=1.0)
        self.display.show(frame)

    def _update_fps(self, now_ms):
        self.fps_frames += 1
        elapsed = ticks_delta(now_ms, self.last_fps_ms)
        if elapsed >= 1000:
            self.fps = self.fps_frames * 1000.0 / elapsed
            self.fps_frames = 0
            self.last_fps_ms = now_ms

    def run(self):
        print(
            "SE Rocket Tracker {0} ready ({1})".format(
                APP_VERSION, "custom" if self.custom_model else "fallback"
            ),
            flush=True,
        )
        self._write("B,SE_TRACKER,{0},{1},{2},{3}".format(
            APP_VERSION, self.active_mode,
            "CUSTOM" if self.custom_model else "FALLBACK", MOUNT_PROFILE))
        while not app.need_exit():
            now_ms = time.ticks_ms()
            self._read_commands()
            if ticks_delta(now_ms, self.last_status_ms) >= 2000:
                self._write(
                    "B,SE_TRACKER,{0},{1},{2},{3}".format(
                        APP_VERSION, self.active_mode,
                        "CUSTOM" if self.custom_model else "FALLBACK",
                        MOUNT_PROFILE
                    )
                )
                self.last_status_ms = now_ms
            frame = self.camera.read()
            if self.enabled:
                self._run_enabled_frame(frame, now_ms)
            self._send_target(now_ms)
            self._update_fps(now_ms)
            if ticks_delta(now_ms, self.last_preview_ms) >= PREVIEW_INTERVAL_MS:
                self._draw_preview(frame)
                self.last_preview_ms = now_ms
            self.frame_index += 1
            # Keep the sensor alive while idle, but do not heat the SoC by
            # rendering 60 preview frames per second before the user arms it.
            time.sleep_ms(1 if self.enabled else IDLE_FRAME_INTERVAL_MS)


def show_fatal(message):
    try:
        disp = display.Display()
        canvas = image.Image(disp.width(), disp.height())
        canvas.draw_string(4, 4, "SE Rocket Tracker ERROR\n" + message, image.COLOR_RED, scale=1.0)
        disp.show(canvas)
    except Exception:
        pass


try:
    RocketTracker().run()
except Exception as exception:
    import traceback
    error_text = traceback.format_exc()
    print(error_text)
    show_fatal(str(exception))
    while not app.need_exit():
        time.sleep_ms(200)
