import SwiftUI

struct SettingsView: View {
	@ObservedObject var store: CardStore
	@Environment(\.dismiss) private var dismiss
	@State private var key = ""
	@State private var relayAddress = ""
	@State private var style: TeachingStyle = .direct

	var body: some View {
		NavigationStack {
			Form {
				Section {
					SecureField("AIza... 或 sk-ant-...", text: $key)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} header: {
					Text("API key")
				} footer: {
					Text("Google AI Studio 的 key（AIza 開頭）有免費額度，貼上就會走 Gemini。貼 Anthropic 的 key（sk-ant 開頭）就走 Claude。")
				}
				Section {
					TextField("sehha555demacbook-pro.local", text: $relayAddress)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.URL)
				} header: {
					Text("Mac 中繼站（選填）")
				} footer: {
					Text("Mac 上先跑 mac-relay/server.py，這裡填 Mac 的名字，就會優先用 Claude Code 訂閱、不吃 API。同一個 Wi-Fi 填「名字.local」；裝了 Tailscale 填它給的機器名，在外面也通。連不上會自動改用上面的 key。")
				}
				Section {
					Picker("口吻", selection: $style) {
						ForEach(TeachingStyle.allCases, id: \.self) { style in
							Text(style.label).tag(style)
						}
					}
					.pickerStyle(.inline)
					.labelsHidden()
				} header: {
					Text("點開步驟時的講法")
				} footer: {
					Text("兩種都分步驟。給提示：每步只講要做什麼、往哪走，不算完、不給結果，讓你自己算。直接給做法：每步寫到照著就能做。")
				}
				if !store.isShared {
					Section {
						Text("目前是免費簽章，分享浮層和這裡各存各的樹。改用付費開發者帳號之後會自動合併。")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
			}
			.navigationTitle("設定")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("完成") {
						store.apiKey = key
						store.relayAddress = relayAddress
						store.teachingStyle = style
						dismiss()
					}
				}
			}
			.onAppear {
				key = store.apiKey
				relayAddress = store.relayAddress
				style = store.teachingStyle
			}
		}
	}
}
