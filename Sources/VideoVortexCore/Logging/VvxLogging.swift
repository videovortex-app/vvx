import Foundation
import Logging

/// Shared logging bootstrap for all vvx executables.
///
/// Call `VvxLogging.bootstrap()` exactly once at startup in each executable
/// entry point (VvxMain, VvxMcp/main, VvxServe/ServeMain). The implementation
/// uses a lazy static to guarantee the factory is registered exactly once,
/// even if called multiple times or if loggers are created before bootstrap.
///
/// All log output goes to stderr so it never contaminates stdout, which is
/// reserved exclusively for JSON/NDJSON payloads and MCP responses.
public enum VvxLogging {

    private static let _bootstrapOnce: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
    }()

    /// Configures swift-log to write all log levels to stderr.
    /// Safe to call multiple times — only the first call takes effect.
    public static func bootstrap() {
        _ = _bootstrapOnce
    }
}
