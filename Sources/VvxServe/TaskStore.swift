import Foundation
import VideoVortexCore

// MARK: - Task status enum

public enum TaskStatus: String, Codable, Sendable {
    case queued
    case downloading
    case processing
    case completed
    case failed
}

// MARK: - Active download record

public struct ActiveTask: Sendable {
    public let taskId: UUID
    public let url: String
    public var status: TaskStatus
    public var progressPercent: Double
    public var speed: String
    public var eta: String
    public var title: String?
    public var resolution: String?
    public var result: VideoMetadata?
    public var error: String?
    public let queuedAt: Date
    public var completedAt: Date?
}

// MARK: - Task store (actor for safe concurrent access)

/// Thread-safe store for active and recently completed download tasks.
/// The Local Agent API reads and writes through this actor.
public actor TaskStore {

    private var tasks: [UUID: ActiveTask] = [:]

    public init() {}

    public func create(taskId: UUID, url: String) {
        tasks[taskId] = ActiveTask(
            taskId: taskId,
            url: url,
            status: .queued,
            progressPercent: 0,
            speed: "--",
            eta: "--:--",
            queuedAt: .now
        )
    }

    public func update(taskId: UUID, _ block: (inout ActiveTask) -> Void) {
        guard tasks[taskId] != nil else { return }
        block(&tasks[taskId]!)
    }

    public func get(taskId: UUID) -> ActiveTask? {
        tasks[taskId]
    }

    public func all() -> [ActiveTask] {
        Array(tasks.values).sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Remove completed/failed tasks older than 1 hour to prevent unbounded growth.
    public func pruneOld() {
        let cutoff = Date().addingTimeInterval(-3600)
        tasks = tasks.filter { _, task in
            guard task.status == .completed || task.status == .failed else { return true }
            return (task.completedAt ?? task.queuedAt) > cutoff
        }
    }
}
