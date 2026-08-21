"""SE selectable tracker for MaixCAM Lite.

MaixCAM is the only vision authority.  The iPhone selects one mode, MaixCAM
runs only that detector/class group, preserves one identity through ByteTrack,
and sends a filtered target to the ESP32 over UART1.  The ESP32 owns all servo
timing and safety limits.
"""

from maix import app, camera, display, err, image, nn, pinmap, time, tracker, uart
import math
import os
import gc


APP_VERSION = "1.4.0"
MODEL_PATH = "/maixapp/apps/se_rocket_tracker/models/se_water_rocket_yolo11n.mud"
FALLBACK_MODEL_PATH = "/root/models/yolo11n.mud"

UART_DEVICE = "/dev/ttyS1"
UART_BAUD = 115200
UART_TX_PIN = "A19"
UART_RX_PIN = "A18"

DETECT_CONFIDENCE = 0.16
DETECT_IOU = 0.42
ACQUIRE_SCORE_MIN = 0.29
REACQUIRE_SCORE_MIN = 0.22
ASSOCIATE_SCORE_MIN = 0.27
LOCK_CONFIRM_FRAMES = 2
LOST_AFTER_FRAMES = 4
DROP_AFTER_FRAMES = 22
MAX_PREDICT_SECONDS = 0.50
PREVIEW_EVERY_N_FRAMES = 6
IDLE_FRAME_INTERVAL_MS = 120
ENROLL_DURATION_MS = 3000
ENROLL_REPORT_INTERVAL_MS = 80
ENROLL_MIN_VISIBLE_RATIO = 0.25

STATE_IDLE = 0
STATE_ACQUIRE = 1
STATE_LOCKED = 2
STATE_WEAK = 3
STATE_LOST = 4

SUPPORTED_MODES = ("ROCKET", "PERSON", "ANIMAL", "OBJECT")
ANIMAL_CLASS_IDS = list(range(14, 24))
OBJECT_CLASS_IDS = list(range(1, 14)) + list(range(24, 80))


def clamp(value, low, high):
    return low if value < low else high if value > high else value


def ticks_delta(now, before):
    value = now - before
    return value if value >= 0 else 1


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
        self.last_ms = 0

    def reset(self):
        self.valid = False
        self.vx = self.vy = 0.0
        self.last_ms = 0

    def predict(self, now_ms):
        if not self.valid:
            return None
        dt = clamp(ticks_delta(now_ms, self.last_ms) / 1000.0, 0.0, MAX_PREDICT_SECONDS)
        return self.cx + self.vx * dt, self.cy + self.vy * dt, self.w, self.h

    def update(self, box, now_ms, confidence):
        x, y, w, h = box
        measured_x = x + w * 0.5
        measured_y = y + h * 0.5
        if not self.valid:
            self.valid = True
            self.cx, self.cy = measured_x, measured_y
            self.w, self.h = float(w), float(h)
            self.vx = self.vy = 0.0
            self.last_ms = now_ms
            return

        dt = clamp(ticks_delta(now_ms, self.last_ms) / 1000.0, 0.01, 0.20)
        predicted_x = self.cx + self.vx * dt
        predicted_y = self.cy + self.vy * dt
        residual_x = measured_x - predicted_x
        residual_y = measured_y - predicted_y
        alpha = clamp(0.36 + confidence * 0.34, 0.40, 0.74)
        beta = clamp(0.05 + confidence * 0.08, 0.06, 0.14)
        self.cx = predicted_x + alpha * residual_x
        self.cy = predicted_y + alpha * residual_y
        # Damp residual velocity before adding the new measurement.  Without
        # this, one noisy box can leave a non-zero feed-forward command for
        # several frames and make an MG995 twitch around a stationary target.
        self.vx = clamp(self.vx * 0.88 + beta * residual_x / dt,
                        -1500.0, 1500.0)
        self.vy = clamp(self.vy * 0.88 + beta * residual_y / dt,
                        -1500.0, 1500.0)
        size_alpha = 0.24 + confidence * 0.14
        self.w += size_alpha * (w - self.w)
        self.h += size_alpha * (h - self.h)
        self.last_ms = now_ms

    def coast(self, now_ms):
        predicted = self.predict(now_ms)
        if predicted is None:
            return
        self.cx, self.cy, self.w, self.h = predicted
        self.vx *= 0.90
        self.vy *= 0.90
        self.last_ms = now_ms


class RocketTracker:
    def __init__(self):
        self.custom_model = os.path.exists(MODEL_PATH)
        self.active_mode = "ROCKET"
        selected_model, self.valid_class_ids = self._mode_configuration(self.active_mode)
        self.detector_path = selected_model
        self.detector = nn.YOLO11(model=selected_model, dual_buff=True)
        self.camera = camera.Camera(
            self.detector.input_width(),
            self.detector.input_height(),
            self.detector.input_format(),
        )
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
        self.last_box = None
        self.last_confidence = 0.0
        self.rx_buffer = ""
        self.last_status_ms = 0
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
        self.enrollment_class_id = -1
        self.appearance_template = None

    def _mode_configuration(self, mode):
        if mode == "ROCKET":
            return (MODEL_PATH, [0]) if self.custom_model else (FALLBACK_MODEL_PATH, [39])
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
        self.state = STATE_ACQUIRE if self.enabled else STATE_IDLE
        self._clear_target()
        if self.enabled:
            self._begin_enrollment()
        print("Tracking mode: {0}".format(mode), flush=True)
        return True

    def _new_byte_tracker(self):
        return tracker.ByteTracker(
            35,   # retain identity briefly when detections disappear
            0.18,
            0.28,
            0.76,
            12,
        )

    def _open_uart(self):
        err.check_raise(pinmap.set_pin_function(UART_TX_PIN, "UART1_TX"), "UART TX mapping failed")
        err.check_raise(pinmap.set_pin_function(UART_RX_PIN, "UART1_RX"), "UART RX mapping failed")
        return uart.UART(UART_DEVICE, UART_BAUD)

    def _write(self, payload):
        self.serial.write_str(make_packet(payload))

    def _read_commands(self):
        data = self.serial.read()
        if not data:
            return
        try:
            self.rx_buffer += bytes(data).decode("ascii", errors="ignore")
        except Exception:
            return
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
            elif command == "PING":
                print("UART command: PING", flush=True)
                self._write("A,{0},PONG,{1},{2}".format(parts[1], APP_VERSION, self.active_mode))

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
        self.last_box = None
        self.last_confidence = 0.0
        self.filter.reset()

    def _begin_enrollment(self):
        self.enrolling = True
        self.enroll_started_ms = time.ticks_ms()
        self.enroll_last_report_ms = 0
        self.enroll_total_frames = 0
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self.enrollment_class_id = -1
        self.appearance_template = None
        self.state = STATE_ACQUIRE
        self._write("E,0,{0},START".format(self.active_mode))

    def _cancel_enrollment(self):
        self.enrolling = False
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}

    def _appearance_signature(self, frame, box):
        """Tiny colour/shape descriptor for re-identifying the enrolled subject.

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
        for fy in (0.22, 0.40, 0.58, 0.76):
            py = int(clamp(y + h * fy, 0, height - 1))
            for fx in (0.22, 0.40, 0.58, 0.76):
                px = int(clamp(x + w * fx, 0, width - 1))
                try:
                    pixel = frame.get_pixel(px, py, True)
                except Exception:
                    return None
                if not isinstance(pixel, (tuple, list)) or len(pixel) < 3:
                    return None
                samples.append((float(pixel[0]), float(pixel[1]), float(pixel[2])))
        if not samples:
            return None
        count = float(len(samples))
        means = [sum(pixel[channel] for pixel in samples) / (255.0 * count)
                 for channel in range(3)]
        spreads = []
        for channel in range(3):
            mean_raw = means[channel] * 255.0
            variance = sum((pixel[channel] - mean_raw) ** 2 for pixel in samples) / count
            spreads.append(math.sqrt(variance) / 128.0)
        aspect = clamp(math.log(max(0.12, w / float(max(1, h)))) / 2.5,
                       -1.0, 1.0)
        return means + spreads + [aspect]

    def _appearance_similarity(self, signature):
        if signature is None or self.appearance_template is None:
            return None
        colour_error = sum(abs(signature[i] - self.appearance_template[i])
                           for i in range(6)) / 6.0
        shape_error = abs(signature[6] - self.appearance_template[6])
        return clamp(1.0 - colour_error * 1.45 - shape_error * 0.18, 0.0, 1.0)

    def _detections_to_tracks(self, objects):
        converted = []
        for obj in objects:
            if obj.class_id not in self.valid_class_ids:
                continue
            if (not self.enrolling and self.enrollment_class_id >= 0 and
                    obj.class_id != self.enrollment_class_id):
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
                    return (raw_confidence * 0.58 + appearance * 0.32 +
                            centre_prior * 0.03 + size_prior * 0.07), box
                return (raw_confidence * 0.82 + centre_prior * 0.08 +
                        size_prior * 0.10), box
            return (raw_confidence * 0.68 + centre_prior * 0.22 +
                    size_prior * 0.10), box

        score = raw_confidence * 0.34
        if track_item.id == self.target_id:
            score += 0.30
        elif self.appearance_template is not None:
            appearance = self._appearance_similarity(
                self._appearance_signature(frame, box)
            )
            if appearance is not None:
                score += appearance * 0.24
        if self.last_box is not None:
            overlap = iou(box, self.last_box)
            score += overlap * 0.10
            old_area = max(1.0, self.last_box[2] * self.last_box[3])
            new_area = max(1.0, obj.w * obj.h)
            score += (min(old_area, new_area) / max(old_area, new_area)) * 0.06
        predicted = self.filter.predict(now_ms)
        if predicted is not None:
            px, py, _, _ = predicted
            diagonal = math.sqrt(camera_width ** 2 + camera_height ** 2)
            distance = math.sqrt((cx - px) ** 2 + (cy - py) ** 2) / max(1.0, diagonal)
            score += clamp(1.0 - distance * 4.5, 0.0, 1.0) * 0.20
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
        self.enroll_started_ms = now_ms
        self.enroll_last_report_ms = 0
        self.enroll_total_frames = 0
        self.enroll_votes = {}
        self.enroll_last_seen = {}
        self.enroll_signature_sums = {}
        self.enroll_signature_counts = {}
        self._write("E,0,{0},RETRY".format(self.active_mode))

    def _update_enrollment(self, tracks, frame, now_ms):
        self.enroll_total_frames += 1
        candidate = self._select_enrollment_candidate(tracks)
        if candidate is not None:
            obj = candidate.history[-1]
            box = (obj.x, obj.y, obj.w, obj.h)
            target_id = candidate.id
            self.enroll_votes[target_id] = self.enroll_votes.get(target_id, 0) + 1
            self.enroll_last_seen[target_id] = (
                box, clamp(candidate.score, 0.0, 1.0), obj.class_id
            )
            if self.frame_index % 2 == 0:
                signature = self._appearance_signature(frame, box)
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

        if not self.enroll_votes:
            self._restart_enrollment(now_ms)
            return
        best_id = max(self.enroll_votes, key=self.enroll_votes.get)
        visible_ratio = self.enroll_votes[best_id] / float(max(1, self.enroll_total_frames))
        if visible_ratio < ENROLL_MIN_VISIBLE_RATIO or best_id not in self.enroll_last_seen:
            self._restart_enrollment(now_ms)
            return

        box, confidence, class_id = self.enroll_last_seen[best_id]
        self.target_id = best_id
        self.enrollment_class_id = class_id
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = True
        self.confirm_count = LOCK_CONFIRM_FRAMES
        self.missing_frames = 0
        self.last_box = box
        self.last_confidence = confidence
        self.filter.reset()
        self.filter.update(box, now_ms, confidence)
        signature_count = self.enroll_signature_counts.get(best_id, 0)
        if signature_count > 0:
            self.appearance_template = [
                value / signature_count
                for value in self.enroll_signature_sums[best_id]
            ]
        self.enrolling = False
        self.state = STATE_LOCKED
        self._write("E,100,{0},READY".format(self.active_mode))
        print("Subject enrolled: mode={0} id={1} class={2} visible={3:.0f}%".format(
            self.active_mode, best_id, class_id, visible_ratio * 100.0
        ), flush=True)

    def _update_target(self, selected, now_ms):
        if selected is None:
            self.missing_frames += 1
            self.confirm_count = 0
            self.pending_target_id = -1
            self.pending_target_frames = 0
            if self.filter.valid and self.missing_frames <= DROP_AFTER_FRAMES:
                self.filter.coast(now_ms)
                self.state = STATE_WEAK if self.missing_frames < LOST_AFTER_FRAMES else STATE_LOST
            else:
                self.state = STATE_ACQUIRE
                self.target_id = -1
                self.last_box = None
                self.filter.reset()
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
            self.filter.update(box, now_ms, confidence)
            self.last_box = box
            self.last_confidence = confidence
            self.missing_frames = 0
            if self.pending_target_frames >= LOCK_CONFIRM_FRAMES:
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
            if self.pending_target_frames < LOCK_CONFIRM_FRAMES:
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
        self.filter.update(box, now_ms, confidence)
        self.last_box = box
        self.last_confidence = confidence
        self.missing_frames = 0
        self.pending_target_id = -1
        self.pending_target_frames = 0
        self.has_ever_locked = True
        self.state = STATE_LOCKED

    def _send_target(self, now_ms):
        self.sequence = (self.sequence + 1) & 0xFFFF
        if not self.enabled or self.enrolling or not self.filter.valid:
            payload = "T,{0},{1},500,500,0,0,0,0,0,{2}".format(
                self.sequence, now_ms, self.state
            )
            self._write(payload)
            return

        width = max(1, self.camera.width())
        height = max(1, self.camera.height())
        cx = int(clamp(self.filter.cx / width * 1000.0, 0, 1000))
        cy = int(clamp(self.filter.cy / height * 1000.0, 0, 1000))
        bw = int(clamp(self.filter.w / width * 1000.0, 0, 1000))
        bh = int(clamp(self.filter.h / height * 1000.0, 0, 1000))
        conf = int(clamp(self.last_confidence * 100.0, 0, 100))
        vx = int(clamp(self.filter.vx / width * 1000.0, -2500, 2500))
        vy = int(clamp(self.filter.vy / height * 1000.0, -2500, 2500))
        payload = "T,{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}".format(
            self.sequence, now_ms, cx, cy, bw, bh, conf, vx, vy, self.state
        )
        self._write(payload)

    def _draw_preview(self, frame):
        width, height = frame.width(), frame.height()
        color = image.COLOR_GREEN if self.state == STATE_LOCKED else image.COLOR_YELLOW
        frame.draw_cross(width // 2, height // 2, color=image.COLOR_WHITE, size=8, thickness=1)
        if self.filter.valid:
            x = int(self.filter.cx - self.filter.w * 0.5)
            y = int(self.filter.cy - self.filter.h * 0.5)
            frame.draw_rect(x, y, int(self.filter.w), int(self.filter.h), color=color, thickness=2)
            frame.draw_cross(int(self.filter.cx), int(self.filter.cy), color=color, size=5, thickness=2)
        label = "SE {0} {1}  {2}%  {3:.1f}fps".format(
            self.active_mode,
            ("3S" if self.enrolling else "LOCK" if self.state == STATE_LOCKED else "FIND"),
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
        self._write("B,SE_TRACKER,{0},{1},{2}".format(
            APP_VERSION, self.active_mode,
            "CUSTOM" if self.custom_model else "FALLBACK"))
        while not app.need_exit():
            now_ms = time.ticks_ms()
            self._read_commands()
            if ticks_delta(now_ms, self.last_status_ms) >= 2000:
                self._write(
                    "B,SE_TRACKER,{0},{1},{2}".format(
                        APP_VERSION, self.active_mode,
                        "CUSTOM" if self.custom_model else "FALLBACK"
                    )
                )
                self.last_status_ms = now_ms
            frame = self.camera.read()
            if self.enabled:
                objects = self.detector.detect(
                    frame,
                    conf_th=DETECT_CONFIDENCE,
                    iou_th=DETECT_IOU,
                )
                tracks = self._detections_to_tracks(objects)
                if self.enrolling:
                    self._update_enrollment(tracks, frame, now_ms)
                else:
                    selected = self._select_target(tracks, now_ms, frame)
                    self._update_target(selected, now_ms)
            self._send_target(now_ms)
            self._update_fps(now_ms)
            if self.frame_index % PREVIEW_EVERY_N_FRAMES == 0:
                self._draw_preview(frame)
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
