import Foundation

/// The UI consumes turn snapshots, not provider clients. A seam for lifecycle tests.
protocol ResearchRunning {
    func run(_ turn: ResearchTurn,
             mode: ResearchRunner.Mode,
             history: [ResearchTurn],
             onUpdate: @escaping (ResearchTurn) -> Void) async -> ResearchTurn
}
