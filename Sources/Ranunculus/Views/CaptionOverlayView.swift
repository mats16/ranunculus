import SwiftUI

/// フローティングオーバーレイに表示する字幕ビュー。
struct CaptionOverlayView: View {
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            if !viewModel.captionText.isEmpty {
                Text(viewModel.captionText)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if !viewModel.partialText.isEmpty {
                Text(viewModel.partialText)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 700)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.78))
        )
        .padding(.horizontal, 8)
    }
}
