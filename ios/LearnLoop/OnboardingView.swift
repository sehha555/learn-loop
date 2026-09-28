import SwiftUI

/// 第一次打開 app：問用哪隻手寫字，決定側邊的東西放哪邊。之後在設定裡可以改
struct OnboardingView: View {
	@ObservedObject var store: CardStore

	var body: some View {
		VStack(spacing: 32) {
			Spacer()
			VStack(spacing: 12) {
				Text("你用哪隻手寫字？")
					.font(.largeTitle.weight(.bold))
				Text("講解和題目會放在另一邊，寫字時手不會擋住。之後在設定裡可以改。")
					.font(.body)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			HStack(spacing: 24) {
				ForEach(Handedness.allCases, id: \.self) { hand in
					Button {
						store.handedness = hand
					} label: {
						VStack(spacing: 12) {
							Image(systemName: "hand.raised.fill")
								.font(.system(size: 56))
								.scaleEffect(x: hand == .left ? -1 : 1)
							Text(hand.label)
								.font(.title2.weight(.semibold))
						}
						.frame(width: 200, height: 180)
						.background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
					}
					.buttonStyle(.plain)
					.foregroundStyle(Color.accentColor)
				}
			}
			Spacer()
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(.systemBackground))
	}
}
