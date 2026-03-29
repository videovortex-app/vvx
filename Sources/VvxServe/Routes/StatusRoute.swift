import Foundation
import Hummingbird
import VideoVortexCore

struct TaskStatusResponse: Encodable {
    let taskId: String
    let url: String
    let status: String
    let progressPercent: Double
    let speed: String
    let eta: String
    let title: String?
    let resolution: String?
    let result: VideoMetadata?
    let error: String?
    let queuedAt: String
    let completedAt: String?
}

func handleStatus(
    taskIdString: String,
    taskStore: TaskStore
) async throws -> Response {
    guard let taskId = UUID(uuidString: taskIdString),
          let task = await taskStore.get(taskId: taskId)
    else {
        return jsonError(status: .notFound, message: "Task not found: \(taskIdString)")
    }

    let formatter = ISO8601DateFormatter()
    let response = TaskStatusResponse(
        taskId: task.taskId.uuidString,
        url: task.url,
        status: task.status.rawValue,
        progressPercent: task.progressPercent,
        speed: task.speed,
        eta: task.eta,
        title: task.title,
        resolution: task.resolution,
        result: task.result,
        error: task.error,
        queuedAt: formatter.string(from: task.queuedAt),
        completedAt: task.completedAt.map { formatter.string(from: $0) }
    )
    return try jsonResponse(response)
}
