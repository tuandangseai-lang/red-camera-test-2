import CoreGraphics
import Foundation

struct RocketMotionEstimate {
    let filteredRect: CGRect
    let predictedPoint: CGPoint
    let velocity: CGVector
}

/// Bộ lọc alpha-beta cho một mục tiêu duy nhất.
///
/// Camera cung cấp vị trí có nhiễu, còn servo cần vị trí ở tương lai vì luôn có
/// độ trễ cơ khí. Bộ lọc giữ vận tốc theo đơn vị "tỉ lệ khung hình / giây" và
/// chỉ cho phép các phép đo yếu thay đổi quỹ đạo một lượng nhỏ.
struct RocketMotionFilter {
    private(set) var isInitialized = false

    private var center = CGPoint(x: 0.5, y: 0.5)
    private var velocity = CGVector.zero
    private var size = CGSize(width: 0.12, height: 0.18)
    private var lastTimestamp: TimeInterval = 0

    mutating func reset(rect: CGRect, timestamp: TimeInterval) {
        let clipped = Self.clipped(rect)
        center = CGPoint(x: clipped.midX, y: clipped.midY)
        size = clipped.size
        velocity = .zero
        lastTimestamp = timestamp
        isInitialized = true
    }

    mutating func clear() {
        isInitialized = false
        center = CGPoint(x: 0.5, y: 0.5)
        velocity = .zero
        size = CGSize(width: 0.12, height: 0.18)
        lastTimestamp = 0
    }

    mutating func update(
        rect: CGRect,
        confidence: Double,
        timestamp: TimeInterval,
        isDetectorMeasurement: Bool
    ) -> RocketMotionEstimate {
        let measurement = Self.clipped(rect)
        guard isInitialized else {
            reset(rect: measurement, timestamp: timestamp)
            return estimate(at: timestamp)
        }

        let dt = CGFloat(max(1.0 / 120.0, min(0.12, timestamp - lastTimestamp)))
        let predictedCenter = CGPoint(
            x: center.x + velocity.dx * dt,
            y: center.y + velocity.dy * dt
        )
        let measuredCenter = CGPoint(x: measurement.midX, y: measurement.midY)
        let residual = CGVector(
            dx: measuredCenter.x - predictedCenter.x,
            dy: measuredCenter.y - predictedCenter.y
        )
        let residualLength = hypot(residual.dx, residual.dy)

        // Detector AI là mốc hiệu chỉnh đáng tin cậy hơn tracker quang học.
        // Phép đo yếu và nhảy xa chỉ kéo nhẹ bộ lọc, tránh servo giật sang nền.
        let normalizedConfidence = CGFloat(max(0, min(1, confidence)))
        var alpha: CGFloat = isDetectorMeasurement ? 0.72 : 0.42
        alpha *= 0.55 + normalizedConfidence * 0.45
        if residualLength > max(0.16, max(size.width, size.height) * 1.8),
           confidence < 0.72 {
            alpha *= 0.16
        }
        let beta: CGFloat = isDetectorMeasurement ? 0.20 : 0.085

        center = CGPoint(
            x: predictedCenter.x + alpha * residual.dx,
            y: predictedCenter.y + alpha * residual.dy
        )
        velocity = CGVector(
            dx: velocity.dx + beta * residual.dx / dt,
            dy: velocity.dy + beta * residual.dy / dt
        )

        // Giới hạn vận tốc giúp một frame lỗi không tạo lệnh servo cực lớn.
        let speed = hypot(velocity.dx, velocity.dy)
        let maximumSpeed: CGFloat = 5.0
        if speed > maximumSpeed {
            let scale = maximumSpeed / speed
            velocity = CGVector(dx: velocity.dx * scale, dy: velocity.dy * scale)
        }

        let sizeAlpha: CGFloat = isDetectorMeasurement ? 0.55 : 0.18
        size = CGSize(
            width: size.width * (1 - sizeAlpha) + measurement.width * sizeAlpha,
            height: size.height * (1 - sizeAlpha) + measurement.height * sizeAlpha
        )
        lastTimestamp = timestamp
        return estimate(at: timestamp)
    }

    func estimate(at timestamp: TimeInterval) -> RocketMotionEstimate {
        let dt = CGFloat(isInitialized ? max(0, min(0.18, timestamp - lastTimestamp)) : 0)
        let current = CGPoint(
            x: center.x + velocity.dx * dt,
            y: center.y + velocity.dy * dt
        )
        let speed = hypot(velocity.dx, velocity.dy)

        // 80 ms bù độ trễ cơ bản; mục tiêu càng nhanh thì nhìn trước thêm nhưng
        // không quá 180 ms để tránh vượt xa tên lửa khi nó đổi hướng.
        let leadTime: CGFloat = min(0.18, 0.08 + speed * 0.025)
        let predicted = CGPoint(
            x: Self.clamp(current.x + velocity.dx * leadTime),
            y: Self.clamp(current.y + velocity.dy * leadTime)
        )
        let filteredRect = Self.clipped(CGRect(
            x: current.x - size.width / 2,
            y: current.y - size.height / 2,
            width: size.width,
            height: size.height
        ))
        return RocketMotionEstimate(
            filteredRect: filteredRect,
            predictedPoint: predicted,
            velocity: velocity
        )
    }

    private static func clipped(_ rect: CGRect) -> CGRect {
        let minimumSize: CGFloat = 0.008
        let normalized = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(minimumSize, rect.width),
            height: max(minimumSize, rect.height)
        )
        return normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(0.015, min(0.985, value))
    }
}
