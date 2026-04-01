import Foundation

/// Whisper 処理待ちセグメントの FIFO キュー。
/// Swift actor で同期を保証し、AsyncStream で消費側にジョブを配信する。
actor WhisperQueue {
    /// ストリーム作成前に enqueue されたIDを一時保持する
    private var bufferedIDs: [UUID] = []
    private var continuation: AsyncStream<UUID>.Continuation?

    /// ジョブストリームを生成する。WhisperService が for await で消費する。
    func makeStream() -> AsyncStream<UUID> {
        let (stream, continuation) = AsyncStream<UUID>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        for id in bufferedIDs {
            continuation.yield(id)
        }
        bufferedIDs.removeAll()

        return stream
    }

    func enqueue(segmentID: UUID) {
        if let continuation {
            continuation.yield(segmentID)
        } else {
            bufferedIDs.append(segmentID)
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    func reset() {
        bufferedIDs.removeAll()
        continuation?.finish()
        continuation = nil
    }
}
